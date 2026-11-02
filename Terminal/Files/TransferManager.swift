import Combine
import Foundation

/// Upload/download queue, shared app-wide. Transfers keep running while
/// the file browser is dismissed; TransfersView renders live progress.
/// Three slots max, cancellable by id, progress throttled to 10 Hz.
@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    struct Transfer: Identifiable {
        enum State: Hashable {
            case running, done, failed, cancelled
        }

        let id = UUID()
        let name: String
        let isUpload: Bool
        var progress: Double = 0
        var state: State = .running
        /// Local destination of a download (kept for share/delete later).
        var localURL: URL?
    }

    @Published private(set) var transfers: [Transfer] = []

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var lastProgressPost: [UUID: ContinuousClock.Instant] = [:]
    private var runningCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var reservedNames: Set<String> = []

    private init() {}

    var activeCount: Int {
        transfers.reduce(0) { $0 + ($1.state == .running ? 1 : 0) }
    }

    // MARK: - Queue

    /// Download a remote file into Documents, reporting progress 0…1.
    func download(file: RemoteFile, via service: SFTPService) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let local = uniqueURL(in: docs, named: file.name)

        let transfer = Transfer(name: file.name, isUpload: false, localURL: local)
        transfers.insert(transfer, at: 0)
        let id = transfer.id

        tasks[id] = Task {
            await acquireSlot()
            defer { release(id: id, local: local) }
            guard !Task.isCancelled else { markCancelled(id); return }
            do {
                try await service.download(path: file.path, to: local, totalSize: file.size) { [weak self] fraction in
                    Task { @MainActor in
                        self?.update(id, progress: fraction)
                    }
                }
                markDone(id)
            } catch is CancellationError {
                markCancelled(id)
            } catch {
                markFailed(id)
            }
        }
    }

    /// Upload a local file to a remote path, reporting progress 0…1.
    func upload(local: URL, to remotePath: String, via service: SFTPService) {
        let transfer = Transfer(name: local.lastPathComponent, isUpload: true)
        transfers.insert(transfer, at: 0)
        let id = transfer.id

        tasks[id] = Task {
            await acquireSlot()
            defer { release(id: id, local: nil) }
            guard !Task.isCancelled else { markCancelled(id); return }
            // Picked files are security-scoped; hold access for the transfer.
            let scoped = local.startAccessingSecurityScopedResource()
            defer { if scoped { local.stopAccessingSecurityScopedResource() } }
            do {
                try await service.upload(local: local, to: remotePath) { [weak self] fraction in
                    Task { @MainActor in
                        self?.update(id, progress: fraction)
                    }
                }
                markDone(id)
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
        transfers.removeAll { $0.id == id && $0.state != .running }
    }

    /// Remove the row and delete the downloaded file with it.
    func removeAndDeleteFile(_ id: UUID) {
        guard let transfer = transfers.first(where: { $0.id == id && $0.state != .running }) else { return }
        if let url = transfer.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        transfers.removeAll { $0.id == id }
    }

    func clearFinished() {
        for t in transfers where t.state != .running && !t.isUpload {
            if let url = t.localURL { try? FileManager.default.removeItem(at: url) }
        }
        transfers.removeAll { $0.state != .running }
    }

    // MARK: - Slots

    private func acquireSlot() async {
        if runningCount < 3 {
            runningCount += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        runningCount += 1
    }

    private func releaseSlot() {
        runningCount -= 1
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }

    private func release(id: UUID, local: URL?) {
        tasks[id] = nil
        lastProgressPost[id] = nil
        if let local { reservedNames.remove(local.lastPathComponent) }
        releaseSlot()
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

    private func markDone(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .done
        transfers[index].progress = 1
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

    /// "file.txt" → "file 1.txt", "file 2.txt", … — never clobber a download.
    /// Names are also reserved in-memory so two downloads started in the
    /// same instant can't pick the same target.
    private func uniqueURL(in directory: URL, named name: String) -> URL {
        var safe = (name as NSString).lastPathComponent.replacingOccurrences(of: "..", with: "_")
        if safe.isEmpty || safe.hasPrefix(".") { safe = "download" + safe }
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
}
