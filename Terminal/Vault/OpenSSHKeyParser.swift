import Foundation
import Crypto
import CryptoKit

enum SSHKeyImportError: Error, Equatable {
    case invalidFormat
    case encryptedNeedsPassphrase
    case wrongPassphrase
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case unsupportedKeyType(String)
    case corrupt
}

/// Parses "-----BEGIN OPENSSH PRIVATE KEY-----" (openssh-key-v1) material,
/// including bcrypt-kdf + AES-CTR encrypted keys.
enum OpenSSHKeyParser {

    struct Parsed {
        var type: StoredSSHKey.KeyType
        /// Raw private material suitable for storage in Keychain:
        /// ed25519 → 32-byte seed; ecdsa → scalar (big-endian, curve size).
        var privateMaterial: Data
        var publicKeyLine: String
        var comment: String
    }

    static func parse(_ pem: String, passphrase: String?) throws -> Parsed {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
              trimmed.hasSuffix("-----END OPENSSH PRIVATE KEY-----") else {
            throw SSHKeyImportError.invalidFormat
        }

        let body = trimmed
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)

        guard let blob = Data(base64Encoded: body) else {
            throw SSHKeyImportError.invalidFormat
        }

        var reader = SSHWireReader(blob)
        let magic = try reader.readBytes(15)
        guard magic == Data("openssh-key-v1\0".utf8) else {
            throw SSHKeyImportError.invalidFormat
        }

        let cipher = try reader.readText()
        let kdfName = try reader.readText()
        let kdfOptions = try reader.readString()

        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else { throw SSHKeyImportError.corrupt }

        let publicBlob = try reader.readString()
        var privateSection = try reader.readString()

        // --- Decrypt if needed ---
        if cipher != "none" {
            guard kdfName == "bcrypt" else {
                throw SSHKeyImportError.unsupportedKDF(kdfName)
            }
            guard let passphrase, !passphrase.isEmpty else {
                throw SSHKeyImportError.encryptedNeedsPassphrase
            }
            var kdfReader = SSHWireReader(kdfOptions)
            let salt = try kdfReader.readString()
            let kdfRounds = Int(try kdfReader.readUInt32())
            // Crafted inputs could demand years of hashing — refuse them.
            guard salt.count <= 256, (1...10_000).contains(kdfRounds) else {
                throw SSHKeyImportError.corrupt
            }

            let (keyLen, ivLen): (Int, Int)
            switch cipher {
            case "aes256-ctr": (keyLen, ivLen) = (32, 16)
            case "aes128-ctr": (keyLen, ivLen) = (16, 16)
            case "aes192-ctr": (keyLen, ivLen) = (24, 16)
            default: throw SSHKeyImportError.unsupportedCipher(cipher)
            }

            let derived = BCryptPBKDF.pbkdf(
                password: Data(passphrase.utf8),
                salt: salt,
                keyLength: keyLen + ivLen,
                rounds: kdfRounds
            )
            let key = derived.prefix(keyLen)
            let iv = derived.suffix(ivLen)
            privateSection = try AESCTR.crypt(key: key, iv: iv, data: privateSection)
        } else if kdfName != "none" {
            throw SSHKeyImportError.unsupportedKDF(kdfName)
        }

        // --- Parse private section ---
        var priv = SSHWireReader(privateSection)
        let check0 = try priv.readUInt32()
        let check1 = try priv.readUInt32()
        guard check0 == check1 else {
            throw cipher == "none" ? SSHKeyImportError.corrupt : SSHKeyImportError.wrongPassphrase
        }

        let keyType = try priv.readText()

        // The private section must describe the same key as the public blob.
        var blobCheck = SSHWireReader(publicBlob)
        guard (try? blobCheck.readText()) == keyType else {
            throw SSHKeyImportError.corrupt
        }

        let parsed: Parsed
        switch keyType {
        case "ssh-ed25519":
            let embeddedPub = try priv.readString()
            let privateBlob = try priv.readString()
            guard privateBlob.count == 64 else { throw SSHKeyImportError.corrupt }
            let seed = Data(privateBlob.prefix(32))
            // The blob's embedded public, its private tail and the
            // outer public section must all derive from the same seed —
            // a mismatched keypair would silently fail server-side.
            let blobPub = (try? blobCheck.readString()) ?? Data()
            let derivedPub = try Crypto.Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                .publicKey.rawRepresentation
            guard embeddedPub == blobPub,
                  privateBlob.suffix(32) == derivedPub else {
                throw SSHKeyImportError.corrupt
            }
            parsed = Parsed(
                type: .ed25519,
                privateMaterial: seed,
                publicKeyLine: publicLine(type: keyType, blob: publicBlob),
                comment: (try? priv.readText()) ?? ""
            )

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = try priv.readText()
            let embeddedPoint = try priv.readString()
            var scalar = try priv.readString()
            // strip mpint sign-padding byte
            while scalar.count > 1 && scalar.first == 0 {
                scalar = scalar.dropFirst()
            }
            let type: StoredSSHKey.KeyType
            let curveBytes: Int
            switch curve {
            case "nistp256": (type, curveBytes) = (.p256, 32)
            case "nistp384": (type, curveBytes) = (.p384, 48)
            case "nistp521": (type, curveBytes) = (.p521, 66)
            default: throw SSHKeyImportError.unsupportedKeyType(curve)
            }
            // left-pad to curve size (mpint may be shorter)
            if scalar.count < curveBytes {
                scalar = Data(repeating: 0, count: curveBytes - scalar.count) + scalar
            }
            guard scalar.count == curveBytes else { throw SSHKeyImportError.corrupt }
            // The scalar's derived point must match both the embedded
            // point and the outer blob's — catches corrupt pairings.
            let blobCurve = (try? blobCheck.readText()) ?? ""
            let blobPoint = (try? blobCheck.readString()) ?? Data()
            guard blobCurve == curve,
                  embeddedPoint == blobPoint,
                  (try? derivePoint(type: type, scalar: scalar)) == embeddedPoint else {
                throw SSHKeyImportError.corrupt
            }
            parsed = Parsed(
                type: type,
                privateMaterial: scalar,
                publicKeyLine: publicLine(type: keyType, blob: publicBlob),
                comment: (try? priv.readText()) ?? ""
            )

        default:
            throw SSHKeyImportError.unsupportedKeyType(keyType)
        }

        // The private section ends with deterministic padding 1,2,3,… —
        // anything else means truncation or trailing garbage.
        var expected: UInt8 = 1
        while priv.remaining > 0 {
            guard (try? priv.readBytes(1))?.first == expected else {
                throw SSHKeyImportError.corrupt
            }
            expected &+= 1
        }
        return parsed
    }

    /// Derives the public point from an ecdsa scalar for consistency checks.
    private static func derivePoint(type: StoredSSHKey.KeyType, scalar: Data) throws -> Data {
        switch type {
        case .p256: return try CryptoKit.P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        case .p384: return try CryptoKit.P384.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        case .p521: return try CryptoKit.P521.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        default: throw SSHKeyImportError.unsupportedKeyType("")
        }
    }

    static func isEncrypted(_ pem: String) -> Bool {
        guard let blob = decodeBlob(pem) else { return false }
        var reader = SSHWireReader(blob)
        guard (try? reader.readBytes(15)) == Data("openssh-key-v1\0".utf8),
              let cipher = try? reader.readText() else {
            return false
        }
        return cipher != "none"
    }

    private static func decodeBlob(_ pem: String) -> Data? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        return Data(base64Encoded: body)
    }

    private static func publicLine(type: String, blob: Data) -> String {
        "\(type) \(blob.base64EncodedString())"
    }
}
