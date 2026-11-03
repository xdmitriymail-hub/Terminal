import Foundation

enum SSHWireError: Error {
    case malformed
}

/// Reader for SSH wire format (uint32 length-prefixed fields).
struct SSHWireReader {
    private(set) var data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHWireError.malformed }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.bigEndian
        offset += 4
        return value
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard remaining >= count, count >= 0 else { throw SSHWireError.malformed }
        let slice = data.subdata(in: offset..<offset + count)
        offset += count
        return slice
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        return try readBytes(length)
    }

    mutating func readText() throws -> String {
        guard let text = String(data: try readString(), encoding: .utf8) else {
            throw SSHWireError.malformed
        }
        return text
    }
}

/// Writer for SSH wire format.
struct SSHWireWriter {
    private(set) var data = Data()

    mutating func writeByte(_ byte: UInt8) {
        data.append(byte)
    }

    mutating func writeUInt32(_ value: UInt32) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 4))
    }

    mutating func writeString(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func writeText(_ text: String) {
        writeString(Data(text.utf8))
    }
}

extension SSHWireWriter {
    /// Encodes an OpenSSH public key line "type base64". `blob` is
    /// already the complete SSH wire blob (ed25519PublicKeyBlob /
    /// ecdsaPublicKeyBlob output) and is base64'd as-is — wrapping it
    /// in another wire buffer would double-encode it.
    static func publicKeyLine(type: String, blob: Data) -> String {
        "\(type) \(blob.base64EncodedString())"
    }

    static func ed25519PublicKeyBlob(_ publicKeyBytes: Data) -> Data {
        var w = SSHWireWriter()
        w.writeText("ssh-ed25519")
        w.writeString(publicKeyBytes)
        return w.data
    }

    static func ecdsaPublicKeyBlob(curve: String, point: Data) -> Data {
        var w = SSHWireWriter()
        w.writeText("ecdsa-sha2-\(curve)")
        w.writeText(curve)
        w.writeString(point)
        return w.data
    }
}
