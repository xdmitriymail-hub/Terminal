import Foundation
import Citadel
import NIO

struct RemoteFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64?
    let permissions: UInt32?
    let modified: Date?

    var isSymlink: Bool {
        guard let permissions else { return false }
        return (permissions & 0o170000) == 0o120000
    }
}

/// Thin async facade over Citadel SFTPClient with progress-friendly
/// chunked transfers.
final class SFTPService: @unchecked Sendable {
    private let sftp: Citadel.SFTPClient

    init(sftp: Citadel.SFTPClient) {
        self.sftp = sftp
    }

    var homePath: String {
        get async throws { try await sftp.getRealPath(atPath: ".") }
    }

    func list(path: String) async throws -> [RemoteFile] {
        try await sftp.listDirectory(atPath: path)
            .flatMap(\.components)
            .map { entry in
                let perms = entry.attributes.permissions
                let isDir = perms.map { ($0 & 0o170000) == 0o040000 } ?? entry.filename.hasSuffix("/")
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

    func rename(from: String, to: String) async throws {
        try await sftp.rename(at: from, to: to)
    }

    func chmod(path: String, permissions: UInt32) async throws {
        var attrs = SFTPFileAttributes()
        attrs.permissions = permissions
        try await sftp.setAttributes(at: path, to: attrs)
    }

    /// Reads loop until a true empty read — servers may legally return
    /// short reads mid-file, so "< chunk" is never treated as EOF.
    func readFile(path: String, maxBytes: Int = 4_000_000) async throws -> Data {
        try await sftp.withFile(filePath: path, flags: .read) { file in
            var out = Data()
            out.reserveCapacity(min(maxBytes, 1_000_000))
            var offset: UInt64 = 0
            let chunk = UInt32(256 * 1024)
            while out.count < maxBytes {
                let buffer = try await file.read(from: offset, length: chunk)
                let bytes = buffer.readableBytes
                if bytes == 0 { break }
                out.append(contentsOf: buffer.readableBytesView)
                offset += UInt64(bytes)
            }
            return out
        }
    }

    func writeFile(path: String, data: Data) async throws {
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
            var offset: UInt64 = 0
            let chunk = 256 * 1024
            while offset < data.count {
                let end = min(offset + UInt64(chunk), UInt64(data.count))
                try await file.write(ByteBuffer(data: data[Int(offset)..<Int(end)]), at: offset)
                offset = end
            }
        }
    }

    /// Download to a local file URL in chunks, reporting progress 0…1.
    func download(path: String, to local: URL, totalSize: UInt64?, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await sftp.withFile(filePath: path, flags: .read) { file in
            FileManager.default.createFile(atPath: local.path, contents: nil)
            let handle = try FileHandle(forWritingTo: local)
            defer { try? handle.close() }

            var offset: UInt64 = 0
            let chunk: UInt32 = 256 * 1024
            while true {
                let buffer = try await file.read(from: offset, length: chunk)
                let bytes = buffer.readableBytes
                if bytes == 0 { break }
                try handle.write(Data(buffer.readableBytesView))
                offset += UInt64(bytes)
                if let totalSize, totalSize > 0 {
                    progress?(Double(offset) / Double(totalSize))
                }
            }
        }
        progress?(1)
    }

    /// Upload a local file in chunks, reporting progress 0…1.
    func upload(local: URL, to path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let total = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? UInt64) ?? 0
        let readHandle = try FileHandle(forReadingFrom: local)
        defer { try? readHandle.close() }

        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
            var offset: UInt64 = 0
            let chunk = 256 * 1024
            while let data = try readHandle.read(upToCount: chunk), !data.isEmpty {
                try await file.write(ByteBuffer(data: data), at: offset)
                offset += UInt64(data.count)
                if total > 0 {
                    progress?(Double(offset) / Double(total))
                }
            }
        }
        progress?(1)
    }

    func close() async {
        try? await sftp.close()
    }
}
