import Foundation
import Citadel
import NIO
import os

/// Failures from the staged-commit path that callers may want to
/// distinguish from generic SFTP/network errors.
enum SFTPServiceError: Error, Sendable {
    /// Commit with create-only semantics refused: a file already sits at
    /// the target path. The original was never touched.
    case targetExists(String)
    /// The safe-replace sequence could not finish. The original's bytes
    /// survive at `preservedAt` (either still at the target or at the
    /// quarantine backup path reported here).
    case replaceUnsafe(path: String, preservedAt: String)
}

struct RemoteFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    var isDirectory: Bool
    let size: UInt64?
    let permissions: UInt32?
    let modified: Date?

    var isSymlink: Bool {
        guard let permissions else { return false }
        return (permissions & 0o170000) == 0o120000
    }
}

/// Thin async facade over Citadel SFTPClient with progress-friendly
/// chunked transfers. Mutations are staged through a unique sibling temp
/// file + rename so a dropped connection can never truncate a remote
/// file, and the original is never deleted before its replacement is
/// committed.
///
/// NOTE on atomic overwrite: posix-rename@openssh.com would be the ideal
/// commit primitive, but Citadel 0.12.1 exposes no way to send
/// SSH_FXP_EXTENDED requests (`sendRequest` is internal, `SFTPRequest`
/// has no `.extended` case) and does not surface the negotiated
/// extension list (`sftpVersion` stays internal). The fallback used here
/// is a rename-shuffle that never destroys the original — see
/// `commitTemp(to:overwrite:)`.
final class SFTPService: Sendable {
    private let sftp: Citadel.SFTPClient
    private static let chunk = 256 * 1024

    /// Live-user bookkeeping: the warm cache may invalidate a service
    /// while a transfer still streams through it. Leases delay the
    /// actual channel close until the last user lets go.
    private struct LeaseState: Sendable {
        var count = 0
        var closeWhenDrained = false
        var invalidated = false
    }
    private let leaseState = OSAllocatedUnfairLock(initialState: LeaseState())

    init(sftp: Citadel.SFTPClient) {
        self.sftp = sftp
    }

    var homePath: String {
        get async throws { try await sftp.getRealPath(atPath: ".") }
    }

    /// False once the underlying SFTP channel reports inactive — a warm
    /// cache hit on a dead channel must reopen instead of handing it out.
    var isChannelAlive: Bool {
        sftp.isActive
    }

    // MARK: - Leases

    /// A live user starts depending on this service (a running transfer,
    /// an open browser view). Balanced by `removeLease()`.
    func addLease() {
        leaseState.withLock { $0.count += 1 }
    }

    /// A live user let go. If the service was invalidated meanwhile and
    /// this was the last lease, the channel is finally closed.
    func removeLease() {
        let drained = leaseState.withLock { state -> Bool in
            state.count = max(0, state.count - 1)
            return state.count == 0 && state.closeWhenDrained && !state.invalidated
        }
        if drained { closeInBackground() }
    }

    /// True while any caller still holds a lease.
    var hasLeases: Bool {
        leaseState.withLock { $0.count > 0 }
    }

    /// Stop this service from being handed out again. Closes the channel
    /// immediately when idle; otherwise marks it so the final
    /// `removeLease()` performs the close — never tears a live transfer
    /// off its channel.
    func invalidate() {
        let drained = leaseState.withLock { state -> Bool in
            state.closeWhenDrained = true
            return state.count == 0 && !state.invalidated
        }
        if drained { closeInBackground() }
    }

    private func closeInBackground() {
        leaseState.withLock { $0.invalidated = true }
        Task { await self.close() }
    }

    // MARK: - Listing / attributes

    func list(path: String) async throws -> [RemoteFile] {
        try await sftp.listDirectory(atPath: path)
            .flatMap(\.components)
            .map { entry in
                let perms = entry.attributes.permissions
                let isDir = (perms ?? 0) & 0o170000 == 0o040000 || entry.filename.hasSuffix("/")
                var modified: Date?
                if let amtime = entry.attributes.accessModificationTime {
                    modified = amtime.modificationTime
                }
                return RemoteFile(
                    name: entry.filename,
                    path: (path as NSString).appendingPathComponent(entry.filename),
                    isDirectory: isDir,
                    size: entry.attributes.size,
                    permissions: perms,
                    modified: modified
                )
            }
    }

    func mkdir(path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    func delete(file: RemoteFile) async throws {
        if file.isDirectory {
            try await sftp.rmdir(at: file.path)
        } else {
            try await sftp.remove(at: file.path)
        }
    }

    func remove(path: String) async throws {
        try await sftp.remove(at: path)
    }

    func rename(from: String, to: String) async throws {
        try await sftp.rename(at: from, to: to)
    }

    func chmod(path: String, permissions: UInt32) async throws {
        var attrs = SFTPFileAttributes()
        attrs.permissions = permissions
        try await sftp.setAttributes(at: path, to: attrs)
    }

    /// stat() follows symlinks, so the answer describes the target.
    func stat(path: String) async throws -> SFTPFileAttributes {
        try await sftp.getAttributes(at: path)
    }

    /// Attributes when the path exists, nil only on a genuine
    /// SSH_FX_NO_SUCH_FILE — every other error propagates.
    private func attributesIfPresent(at path: String) async throws -> SFTPFileAttributes? {
        do {
            return try await sftp.getAttributes(at: path)
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            return nil
        } catch SFTPError.errorStatus(let status) where status.errorCode == .noSuchFile {
            return nil
        }
    }

    /// Honest existence check: `false` means the server answered
    /// SSH_FX_NO_SUCH_FILE. Permission denied, dead channels and any
    /// other failure are thrown — never reported as "missing".
    func exists(atPath path: String) async throws -> Bool {
        try await attributesIfPresent(at: path) != nil
    }

    /// Legacy non-throwing variant kept so older call sites still
    /// compile. Fails toward `false` on error: the upload commit layer
    /// enforces no-clobber server-side, so a wrong "absent" answer can
    /// produce a failed transfer but never a silent overwrite.
    /// Migrate to `exists(atPath:)`, which throws.
    @available(*, deprecated, message: "Use exists(atPath:) — it throws on stat errors instead of guessing")
    func exists(path: String) async -> Bool {
        (try? await exists(atPath: path)) ?? false
    }

    /// Reads loop until a true empty read — servers may legally return
    /// short reads mid-file, so "< chunk" is never treated as EOF.
    /// `isComplete` is only true when EOF was actually observed.
    func readFile(path: String, maxBytes: Int = 4_000_000) async throws -> (data: Data, isComplete: Bool) {
        try await sftp.withFile(filePath: path, flags: .read) { file in
            var out = Data()
            out.reserveCapacity(min(maxBytes, 1_000_000))
            var offset: UInt64 = 0
            var sawEOF = false
            while out.count < maxBytes {
                let want = UInt32(min(Self.chunk, maxBytes - out.count))
                let buffer = try await file.read(from: offset, length: want)
                let bytes = buffer.readableBytes
                if bytes == 0 { sawEOF = true; break }
                out.append(contentsOf: buffer.readableBytesView)
                offset += UInt64(bytes)
            }
            if !sawEOF {
                // Hit the cap exactly: the file may be precisely
                // `maxBytes` long. Probe one byte past the end — a real
                // EOF reads empty. A probe failure means "unknown", so
                // report incomplete rather than lie about completeness.
                do {
                    let probe = try await file.read(from: offset, length: 1)
                    sawEOF = probe.readableBytes == 0
                } catch {
                    sawEOF = false
                }
            }
            return (out, sawEOF)
        }
    }

    // MARK: - Staged commits

    /// Unique hidden sibling name for the staged copy.
    private func tempPath(for path: String) -> String {
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        return "\(dir)/.\(ns.lastPathComponent).\(UUID().uuidString).tmp"
    }

    /// Unique hidden sibling name used to quarantine the original while
    /// a staged replacement lands.
    private func backupPath(for path: String) -> String {
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        return "\(dir)/.\(ns.lastPathComponent).\(UUID().uuidString).bak"
    }

    /// Move a fully-written staged file into place.
    ///
    /// - `overwrite: false` = create-only. SFTP v3 RENAME itself refuses
    ///   to replace an existing target, so the policy is enforced
    ///   server-side atomically; on refusal we throw `.targetExists`.
    /// - `overwrite: true` = replace. A plain rename commits atomically
    ///   when the target is absent. When it exists, Citadel 0.12.1 gives
    ///   us no posix-rename@openssh.com channel (no public SSH_FXP_EXTENDED
    ///   API and no visible extension list), so we quarantine-then-move:
    ///   the original is RENAMED aside (never deleted), the staged file
    ///   is renamed in, and only then is the quarantined copy dropped.
    ///   A crash mid-shuffle leaves the original recoverable at the
    ///   `.bak` path — nothing is ever deleted before its replacement
    ///   is committed.
    private func commitTemp(_ tmp: String, to path: String, overwrite: Bool) async throws {
        try Task.checkCancellation()
        do {
            try await sftp.rename(at: tmp, to: path)
            return
        } catch let renameError {
            if renameError is CancellationError { throw renameError }
            // Distinguish "target exists" from real failures by asking
            // the server — v3 status codes can't tell them apart.
            let present: Bool
            do {
                present = try await exists(atPath: path)
            } catch {
                // Can't verify — surface the original rename error.
                throw renameError
            }
            guard present else { throw renameError }
            guard overwrite else {
                throw SFTPServiceError.targetExists(path)
            }
        }

        // Target exists and replacement was requested — safe-replace.
        let backup = backupPath(for: path)
        do {
            try await sftp.rename(at: path, to: backup)
        } catch {
            // Couldn't even move the original aside — leave everything
            // exactly as it was.
            throw SFTPServiceError.replaceUnsafe(path: path, preservedAt: path)
        }
        do {
            try Task.checkCancellation()
            try await sftp.rename(at: tmp, to: path)
        } catch let moveError {
            // Put the original back; if even that fails, say where its
            // bytes survive rather than pretending all is well.
            do {
                try await sftp.rename(at: backup, to: path)
            } catch {
                throw SFTPServiceError.replaceUnsafe(path: path, preservedAt: backup)
            }
            if moveError is CancellationError { throw moveError }
            throw SFTPServiceError.replaceUnsafe(path: path, preservedAt: path)
        }
        // Replacement committed — the quarantined old bytes are litter
        // now; dropping them can't hurt anything. If this fails the
        // user just sees a recoverable .bak sibling.
        try? await sftp.remove(at: backup)
    }

    /// Write a whole file via staged temp + safe commit, preserving the
    /// existing file's permissions when it has any. `overwrite: false`
    /// verifies server-side at commit time that the destination is still
    /// empty (create-only) and fails with `.targetExists` otherwise.
    /// The original is never deleted before its replacement is committed.
    func writeFile(path: String, data: Data, overwrite: Bool = true) async throws {
        let existing = try await attributesIfPresent(at: path)
        if !overwrite, existing != nil {
            throw SFTPServiceError.targetExists(path)
        }
        let tmp = tempPath(for: path)
        var createAttrs = SFTPFileAttributes()
        createAttrs.permissions = existing?.permissions
        do {
            try Task.checkCancellation()
            try await sftp.withFile(
                filePath: tmp,
                flags: [.write, .create, .forceCreate],
                attributes: createAttrs
            ) { file in
                var offset: UInt64 = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    let end = min(offset + UInt64(Self.chunk), UInt64(data.count))
                    try await file.write(ByteBuffer(data: data[Int(offset)..<Int(end)]), at: offset)
                    offset = end
                }
            }
            // Servers may ignore create-time attributes — setstat makes
            // permission preservation explicit. A failure aborts the
            // commit (temp cleaned, original untouched) rather than
            // silently degrading permissions.
            if let perms = existing?.permissions {
                var wanted = SFTPFileAttributes()
                wanted.permissions = perms
                try await sftp.setAttributes(at: tmp, to: wanted)
            }
            try Task.checkCancellation()
            try await commitTemp(tmp, to: path, overwrite: overwrite)
        } catch {
            // Only our own staging file is ever cleaned up.
            try? await sftp.remove(at: tmp)
            throw error
        }
    }

    // MARK: - Local file IO

    /// O_WRONLY|O_CREAT|O_EXCL, mode 0600 — a partial download must be a
    /// fresh private file, never a shared or pre-existing one.
    private static func createFileExclusively(at url: URL) throws -> FileHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.flatMap { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        }
        guard let descriptor, descriptor >= 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Download to a local file URL in chunks, reporting progress 0…1.
    /// The URL is created exclusively — the caller hands us a staging
    /// path and owns the atomic move into place afterwards.
    func download(path: String, to local: URL, totalSize: UInt64?, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await sftp.withFile(filePath: path, flags: .read) { file in
            let handle = try Self.createFileExclusively(at: local)
            var offset: UInt64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let buffer = try await file.read(from: offset, length: UInt32(Self.chunk))
                    let bytes = buffer.readableBytes
                    if bytes == 0 { break }
                    try handle.write(Data(buffer.readableBytesView))
                    offset += UInt64(bytes)
                    if let totalSize, totalSize > 0 {
                        progress?(Double(offset) / Double(totalSize))
                    }
                }
            } catch {
                try? handle.close()
                throw error
            }
            // A failed close can mean lost buffered bytes — surface it
            // rather than pretending the partial file is complete.
            try handle.close()
        }
        progress?(1)
    }

    /// Upload a local file in chunks via staged temp + safe commit,
    /// reporting 0…1. `overwrite: false` verifies server-side at commit
    /// time that the destination is still empty (create-only).
    func upload(local: URL, to path: String, overwrite: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let total = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let readHandle = try FileHandle(forReadingFrom: local)
        defer { try? readHandle.close() }

        let existing = try await attributesIfPresent(at: path)
        if !overwrite, existing != nil {
            throw SFTPServiceError.targetExists(path)
        }

        let tmp = tempPath(for: path)
        var createAttrs = SFTPFileAttributes()
        createAttrs.permissions = existing?.permissions
        do {
            try Task.checkCancellation()
            try await sftp.withFile(
                filePath: tmp,
                flags: [.write, .create, .forceCreate],
                attributes: createAttrs
            ) { file in
                var offset: UInt64 = 0
                while let data = try readHandle.read(upToCount: Self.chunk), !data.isEmpty {
                    try Task.checkCancellation()
                    try await file.write(ByteBuffer(data: data), at: offset)
                    offset += UInt64(data.count)
                    if total > 0 {
                        progress?(Double(offset) / Double(total))
                    }
                }
            }
            if let perms = existing?.permissions {
                var wanted = SFTPFileAttributes()
                wanted.permissions = perms
                try await sftp.setAttributes(at: tmp, to: wanted)
            }
            try Task.checkCancellation()
            try await commitTemp(tmp, to: path, overwrite: overwrite)
        } catch {
            try? await sftp.remove(at: tmp)
            throw error
        }
        progress?(1)
    }

    func close() async {
        try? await sftp.close()
    }
}
