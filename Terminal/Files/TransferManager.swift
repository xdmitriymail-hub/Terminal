import Foundation

/// Upload/download queue, shared app-wide. Transfers keep running while
/// the file browser is dismissed; TransfersView renders live progress.
@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    struct Transfer: Identifiable, Hashable {
        enum State: Hashable {
            case running, done, failed
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

        Task {
            do {
                try await service.download(path: file.path, to: local, totalSize: file.size) { [weak self] fraction in
                    Task { @MainActor in
                        self?.update(id, progress: fraction)
                    }
                }
                finish(id, succeeded: true)
            } catch {
                try? FileManager.default.removeItem(at: local)
                finish(id, succeeded: false)
            }
        }
    }

    /// Upload a local file to a remote path, reporting progress 0…1.
    func upload(local: URL, to remotePath: String, via service: SFTPService) {
        let transfer = Transfer(name: local.lastPathComponent, isUpload: true)
        transfers.insert(transfer, at: 0)
        let id = transfer.id

        Task {
            // Picked files are security-scoped; hold access for the transfer.
            let scoped = local.startAccessingSecurityScopedResource()
            defer { if scoped { local.stopAccessingSecurityScopedResource() } }
            do {
                try await service.upload(local: local, to: remotePath) { [weak self] fraction in
                    Task { @MainActor in
                        self?.update(id, progress: fraction)
                    }
                }
                finish(id, succeeded: true)
            } catch {
                finish(id, succeeded: false)
            }
        }
    }

    // MARK: - Housekeeping

    func remove(_ id: UUID) {
        transfers.removeAll { $0.id == id && $0.state != .running }
    }

    func clearFinished() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: - Private

    private func update(_ id: UUID, progress: Double) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].progress = min(1, max(0, progress))
    }

    private func finish(_ id: UUID, succeeded: Bool) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = succeeded ? .done : .failed
        if succeeded {
            transfers[index].progress = 1
            Haptics.tap()
        } else {
            Haptics.failed()
        }
    }

    /// "file.txt" → "file 1.txt", "file 2.txt", … — never clobber a download.
    /// Remote filenames are server-controlled: flatten path components so
    /// a hostile server can't write outside Documents.
    private func uniqueURL(in directory: URL, named name: String) -> URL {
        var safe = (name as NSString).lastPathComponent.replacingOccurrences(of: "..", with: "_")
        if safe.isEmpty || safe.hasPrefix(".") { safe = "download" + safe }
        var candidate = directory.appendingPathComponent(safe)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (safe as NSString).pathExtension
        let base = (safe as NSString).deletingPathExtension
        var n = 1
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = directory.appendingPathComponent(next)
            n += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}
