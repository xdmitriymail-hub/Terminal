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

    /// Base64 bodies larger than this are rejected BEFORE decode — a
    /// hostile paste must not turn into a giant allocation. ~96 KiB of
    /// decoded material covers every supported key size many times over.
    private static let maxBodyBase64Length = 128 * 1024

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
        guard let blob = decodeBlob(trimmed) else {
            throw SSHKeyImportError.invalidFormat
        }

        let cipher: String
        let kdfName: String
        let publicBlob: Data
        var privateSection: Data
        var reader = SSHWireReader(blob)
        do {
            let magic = try reader.readBytes(15)
            guard magic == Data("openssh-key-v1\0".utf8) else {
                throw SSHKeyImportError.invalidFormat
            }
            cipher = try reader.readText()
            kdfName = try reader.readText()
            let kdfOptions = try reader.readString()

            let keyCount = try reader.readUInt32()
            guard keyCount == 1 else { throw SSHKeyImportError.corrupt }

            publicBlob = try reader.readString()
            privateSection = try reader.readString()
            // openssh-key-v1 carries exactly one key and nothing else —
            // trailing bytes mean a hand-built file.
            guard reader.remaining == 0 else { throw SSHKeyImportError.corrupt }

            // --- Decrypt if needed ---
            if cipher != "none" {
                privateSection = try decryptSection(
                    privateSection,
                    cipher: cipher,
                    kdfName: kdfName,
                    kdfOptions: kdfOptions,
                    passphrase: passphrase
                )
            } else {
                guard kdfName == "none" else {
                    throw SSHKeyImportError.unsupportedKDF(kdfName)
                }
            }
        } catch let error as SSHKeyImportError {
            throw error
        } catch is CancellationError {
            // A cancelled KDF must surface as cancellation, not corruption.
            throw CancellationError()
        } catch {
            throw SSHKeyImportError.corrupt
        }

        let blockSize = cipher == "none" ? 8 : 16
        // CTR is a stream cipher: ciphertext length == padded plaintext
        // length, so the section is block-aligned either way.
        guard privateSection.count % blockSize == 0 else {
            throw SSHKeyImportError.corrupt
        }

        // --- Parse private section ---
        var priv = SSHWireReader(privateSection)
        var blobCheck = SSHWireReader(publicBlob)
        let parsed: Parsed
        do {
            let check0 = try priv.readUInt32()
            let check1 = try priv.readUInt32()
            guard check0 == check1 else {
                throw cipher == "none" ? SSHKeyImportError.corrupt : SSHKeyImportError.wrongPassphrase
            }

            let keyType = try priv.readText()

            // The private section must describe the same key as the
            // public blob.
            guard try blobCheck.readText() == keyType else {
                throw SSHKeyImportError.corrupt
            }

            switch keyType {
            case "ssh-ed25519":
                let embeddedPub = try priv.readString()
                let privateBlob = try priv.readString()
                guard embeddedPub.count == 32, privateBlob.count == 64 else {
                    throw SSHKeyImportError.corrupt
                }
                let blobPub = try blobCheck.readString()
                let seed = Data(privateBlob.prefix(32))
                // The blob's embedded public, the outer public section
                // and the private tail must ALL equal the key derived
                // from the seed — a seed-A/public-B chimera would
                // silently fail server-side.
                let derivedPub = try Crypto.Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                    .publicKey.rawRepresentation
                guard embeddedPub == derivedPub,
                      blobPub == derivedPub,
                      privateBlob.suffix(32) == derivedPub else {
                    throw SSHKeyImportError.corrupt
                }
                parsed = Parsed(
                    type: .ed25519,
                    privateMaterial: seed,
                    publicKeyLine: publicLine(type: keyType, blob: publicBlob),
                    comment: try priv.readText()
                )

            case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
                let expectedCurve = String(keyType.dropFirst("ecdsa-sha2-".count))
                let curve = try priv.readText()
                // keyType and the embedded curve field must agree — a
                // mismatched pair produces a key OpenSSH rejects.
                guard curve == expectedCurve else { throw SSHKeyImportError.corrupt }
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
                let blobCurve = try blobCheck.readText()
                let blobPoint = try blobCheck.readString()
                let derivedPoint: Data
                do {
                    derivedPoint = try derivePoint(type: type, scalar: scalar)
                } catch {
                    throw SSHKeyImportError.corrupt
                }
                guard blobCurve == curve,
                      embeddedPoint == blobPoint,
                      derivedPoint == embeddedPoint else {
                    throw SSHKeyImportError.corrupt
                }
                parsed = Parsed(
                    type: type,
                    privateMaterial: scalar,
                    publicKeyLine: publicLine(type: keyType, blob: publicBlob),
                    comment: try priv.readText()
                )

            default:
                throw SSHKeyImportError.unsupportedKeyType(keyType)
            }

            // The public blob must be consumed exactly — trailing bytes
            // mean a hand-built file.
            guard blobCheck.remaining == 0 else { throw SSHKeyImportError.corrupt }
        } catch let error as SSHKeyImportError {
            throw error
        } catch {
            throw SSHKeyImportError.corrupt
        }

        // The private section ends with deterministic padding 1,2,3,…
        // filling exactly one partial block — empty, oversized or
        // arbitrary padding means truncation or trailing garbage.
        let padLength = priv.remaining
        guard padLength >= 1, padLength <= blockSize else {
            throw SSHKeyImportError.corrupt
        }
        for (index, byte) in privateSection.suffix(padLength).enumerated() {
            guard byte == UInt8(index + 1) else {
                throw SSHKeyImportError.corrupt
            }
        }
        return parsed
    }

    /// Runs bcrypt-kdf + AES-CTR on the private section. Split out so
    /// the KDF's `CancellationError` can be told apart from corruption.
    private static func decryptSection(
        _ section: Data,
        cipher: String,
        kdfName: String,
        kdfOptions: Data,
        passphrase: String?
    ) throws -> Data {
        guard kdfName == "bcrypt" else {
            throw SSHKeyImportError.unsupportedKDF(kdfName)
        }
        guard let passphrase, !passphrase.isEmpty else {
            throw SSHKeyImportError.encryptedNeedsPassphrase
        }
        var kdfReader = SSHWireReader(kdfOptions)
        let salt = try kdfReader.readString()
        let kdfRounds = Int(try kdfReader.readUInt32())
        guard kdfReader.remaining == 0 else { throw SSHKeyImportError.corrupt }
        // Crafted inputs could demand years of hashing — refuse them.
        guard (1...256).contains(salt.count), (1...10_000).contains(kdfRounds) else {
            throw SSHKeyImportError.corrupt
        }

        let keyLen: Int
        let ivLen: Int
        switch cipher {
        case "aes256-ctr": (keyLen, ivLen) = (32, 16)
        case "aes128-ctr": (keyLen, ivLen) = (16, 16)
        case "aes192-ctr": (keyLen, ivLen) = (24, 16)
        default: throw SSHKeyImportError.unsupportedCipher(cipher)
        }

        let derived = try BCryptPBKDF.pbkdf(
            password: Data(passphrase.utf8),
            salt: salt,
            keyLength: keyLen + ivLen,
            rounds: kdfRounds,
            isCancelled: { Task<Never, Never>.isCancelled }
        )
        do {
            return try AESCTR.crypt(key: derived.prefix(keyLen), iv: derived.suffix(ivLen), data: section)
        } catch {
            throw SSHKeyImportError.corrupt
        }
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
        do {
            let magic = try reader.readBytes(15)
            guard magic == Data("openssh-key-v1\0".utf8) else { return false }
            let cipher = try reader.readText()
            return cipher != "none"
        } catch {
            return false
        }
    }

    private static func decodeBlob(_ pem: String) -> Data? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        // Size cap BEFORE base64 decode.
        guard body.count <= maxBodyBase64Length else { return nil }
        return Data(base64Encoded: body)
    }

    private static func publicLine(type: String, blob: Data) -> String {
        "\(type) \(blob.base64EncodedString())"
    }
}
