import Combine
import Foundation

/// Upload/download queue, shared app-wide. Transfers keep running while
/// the file browser is dismissed; TransfersView renders live progress.
/// Three slots max, cancellable by id (queued transfers included),
/// progress throttled to 10 Hz.
@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    struct Transfer: Identifiable {
        enum State: Hashable {
            /// Waiting for a slot — no bytes are moving yet.
            case queued
            case running, done, failed, cancelled

            /// Still owns queue resources (waiting or transferring) —
            /// row removal and cancellation UIs must treat both the
            /// same way.
            var isActive: Bool { self == .queued || self == .running }
        }

        let id = UUID()
        let name: String
        let isUpload: Bool
        var progress: Double = 0
        var state: State = .queued
        /// Local destination of a download — only ever points at the
        /// completed file, never at the .partial staging file.
        var localURL: URL?
    }

    @Published private(set) var transfers: [Transfer] = []

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var lastProgressPost: [UUID: ContinuousClock.Instant] = [:]
    private static let maxConcurrent = 3
    private var runningCount = 0
    /// Permits are handed directly from the releasing task to the
    /// resumed waiter — the waiter's slot is never returned to the pool
    /// in between, so nothing else can steal it.
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var waiterOrder: [UUID] = []
    private var reservedNames: Set<String> = []

    private init() {
        sweepPartials()
    }

    var activeCount: Int {
        transfers.reduce(0) { $0 + ($1.state.isActive ? 1 : 0) }
    }

    // MARK: - Queue

    /// Download a remote file into Documents, reporting progress 0…1.
    /// Bytes land in a hidden `.<name>.partial-<uuid>` sibling and are
    /// atomically moved onto the final name only at EOF — a failed or
    /// cancelled download never leaves a "finished-looking" file behind.
    /// `onSuccess` receives the committed local URL so callers can hand
    /// the file onward — e.g. straight into the system export picker.
    func download(
        file: RemoteFile,
        via service: SFTPService,
        onSuccess: (@MainActor (URL) -> Void)? = nil
    ) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let local = uniqueURL(in: docs, named: file.name)
        let partial = partialURL(for: local, in: docs)

        let transfer = Transfer(name: file.name, isUpload: false)
        transfers.insert(transfer, at: 0)
        let id = transfer.id
        service.addLease()

        tasks[id] = Task {
            do {
                try await acquireSlot(id: id)
            } catch {
                // Cancelled while queued — never held a slot.
                try? FileManager.default.removeItem(at: partial)
                finish(id: id, finalName: local.lastPathComponent, heldSlot: false, service: service)
                markCancelled(id)
                return
            }
            // A slot is definitely held from this point on — every exit
            // (including immediate cancellation) must release it.
            defer {
                finish(id: id, finalName: local.lastPathComponent, heldSlot: true, service: service)
            }
            do {
                try Task.checkCancellation()
                markRunning(id)
                try await service.download(path: file.path, to: partial, totalSize: file.size) { [weak self] fraction in
                    Task { @MainActor in
                        self?.update(id, progress: fraction)
                    }
                }
                try Task.checkCancellation()
                // EOF reached — commit the file to its final name in
                // one atomic same-directory move.
                try FileManager.default.moveItem(at: partial, to: local)
                markDone(id, local: local)
                onSuccess?(local)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: partial)
                markCancelled(id)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                markFailed(id)
            }
        }
    }

    /// Upload a local file to a remote path, reporting progress 0…1.
    /// `overwrite: false` makes the remote commit verify server-side
    /// that the destination is still empty — "Keep Both" can never
    /// clobber a same-named file that appeared meanwhile.
    /// `onSuccess` runs after a successful upload so the caller can
    /// refresh the listing instead of guessing with a fixed delay.
    func upload(
        local: URL,
        to remotePath: String,
        via service: SFTPService,
        overwrite: Bool = true,
        onSuccess: (@MainActor () async -> Void)? = nil
    ) {
        let transfer = Transfer(name: local.lastPathComponent, isUpload: true)
        transfers.insert(transfer, at: 0)
        let id = transfer.id
        service.addLease()

        tasks[id] = Task {
            do {
                try await acquireSlot(id: id)
            } catch {
                finish(id: id, finalName: nil, heldSlot: false, service: service)
                markCancelled(id)
                return
            }
            // A slot is definitely held from this point on.
            defer {
                finish(id: id, finalName: nil, heldSlot: true, service: service)
            }
            // Picked files are security-scoped; hold access for the transfer.
            let scoped = local.startAccessingSecurityScopedResource()
            defer { if scoped { local.stopAccessingSecurityScopedResource() } }
            do {
                try Task.checkCancellation()
                markRunning(id)
                try await service.upload(local: local, to: remotePath, overwrite: overwrite) { [weak self] fraction in
                    Task { @MainActor in
                        self?.update(id, progress: fraction)
                    }
                }
                markDone(id, local: nil)
                await onSuccess?()
            } catch is CancellationError {
                markCancelled(id)
            } catch {
                markFailed(id)
            }
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    // MARK: - Housekeeping

    /// Remove the row only — the downloaded file stays in Documents.
    func remove(_ id: UUID) {
        transfers.removeAll { $0.id == id && !$0.state.isActive }
    }

    /// Remove the row and delete the downloaded file with it.
    func removeAndDeleteFile(_ id: UUID) {
        guard let transfer = transfers.first(where: { $0.id == id && !$0.state.isActive }) else { return }
        if let url = transfer.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        transfers.removeAll { $0.id == id }
    }

    /// Drop finished rows only — downloaded files stay in Documents.
    /// The destructive path is `removeAndDeleteFile` (explicit swipe).
    func clearFinished() {
        transfers.removeAll { !$0.state.isActive }
    }

    /// Leftover `.*.partial-*` staging files from a killed run. Final
    /// names are deliberately NOT touched — a crash during the move can
    /// leave either the partial or the committed file, and only the
    /// partial is disposable.
    private func sweepPartials() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []
        where name.hasPrefix(".") && name.contains(".partial-") {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
        }
    }

    // MARK: - Slots

    /// Acquire one of the three transfer slots. When the pool is full
    /// the caller suspends behind a UUID-keyed waiter; a release hands
    /// the permit straight to the oldest waiter (runningCount is not
    /// decremented on handoff and the resumed waiter does not
    /// re-increment — the slot is never free to be stolen).
    private func acquireSlot(id: UUID) async throws {
        if runningCount < Self.maxConcurrent {
            runningCount += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                waiters[id] = cont
                waiterOrder.append(id)
            }
        } onCancel: {
            // Hop back to the MainActor to remove the waiter and
            // throw — a cancelled task must never stay queued.
            Task { @MainActor [weak self] in
                guard let cont = self?.waiters.removeValue(forKey: id) else { return }
                cont.resume(throwing: CancellationError())
            }
        }
    }

    /// Release a slot. With waiters pending the permit transfers
    /// directly (count unchanged); otherwise the pool actually shrinks.
    private func releaseSlot() {
        while let nextID = waiterOrder.first {
            waiterOrder.removeFirst()
            guard let cont = waiters.removeValue(forKey: nextID) else {
                // Waiter was cancelled between enqueue and now.
                continue
            }
            cont.resume()
            return
        }
        runningCount -= 1
    }

    /// One cleanup path for every exit from a transfer task.
    private func finish(id: UUID, finalName: String?, heldSlot: Bool, service: SFTPService) {
        tasks[id] = nil
        lastProgressPost[id] = nil
        if let finalName { reservedNames.remove(finalName) }
        service.removeLease()
        if heldSlot { releaseSlot() }
    }

    // MARK: - State

    private func update(_ id: UUID, progress: Double) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        let now = ContinuousClock.now
        if progress < 1,
           let last = lastProgressPost[id],
           now - last < .milliseconds(100) {
            return
        }
        lastProgressPost[id] = now
        transfers[index].progress = min(1, max(0, progress))
    }

    private func markRunning(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .running
    }

    private func markDone(_ id: UUID, local: URL?) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .done
        transfers[index].progress = 1
        // Only the completed, moved-into-place file is exposed — never
        // the .partial staging path.
        transfers[index].localURL = local
        Haptics.tap()
    }

    private func markCancelled(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .cancelled
    }

    private func markFailed(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .failed
        Haptics.failed()
    }

    /// Server-supplied name flattened into a safe single component —
    /// shared by downloads, uploads and share staging. Pure function —
    /// deliberately nonisolated so non-actor callers (preview share)
    /// can use it synchronously.
    nonisolated static func sanitizedFileName(_ name: String) -> String {
        var safe = (name as NSString).lastPathComponent.replacingOccurrences(of: "..", with: "_")
        if safe.isEmpty || safe.hasPrefix(".") { safe = "download" + safe }
        return safe
    }

    /// "file.txt" → "file 1.txt", "file 2.txt", … — never clobber a download.
    /// Names are also reserved in-memory so two downloads started in the
    /// same instant can't pick the same target.
    private func uniqueURL(in directory: URL, named name: String) -> URL {
        let safe = Self.sanitizedFileName(name)
        let ext = (safe as NSString).pathExtension
        let base = (safe as NSString).deletingPathExtension
        var n = 0
        var candidate: URL
        repeat {
            let fileName: String
            if n == 0 {
                fileName = safe
            } else {
                fileName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            }
            candidate = directory.appendingPathComponent(fileName)
            n += 1
        } while reservedNames.contains(candidate.lastPathComponent)
            || FileManager.default.fileExists(atPath: candidate.path)
        reservedNames.insert(candidate.lastPathComponent)
        return candidate
    }

    /// Hidden sibling staging path — unique per attempt so two downloads
    /// of the same name can never share a partial file.
    private func partialURL(for final: URL, in directory: URL) -> URL {
        directory.appendingPathComponent(".\(final.lastPathComponent).partial-\(UUID().uuidString)")
    }
}
