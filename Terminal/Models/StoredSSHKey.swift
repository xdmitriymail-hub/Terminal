import Foundation

struct StoredSSHKey: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var type = KeyType.ed25519
    var publicKeyOpenSSH = ""
    var created = Date()
    var inSecureEnclave = false
    var requiresBiometry = false
    var encryptedImport = false

    enum KeyType: String, Codable, Hashable, Sendable {
        case ed25519
        case p256
        case p384
        case p521
        case secureEnclaveP256
        case rsa

        var sshPrefix: String {
            switch self {
            case .ed25519: return "ssh-ed25519"
            case .p256: return "ecdsa-sha2-nistp256"
            case .p384: return "ecdsa-sha2-nistp384"
            case .p521: return "ecdsa-sha2-nistp521"
            case .secureEnclaveP256: return "ecdsa-sha2-nistp256"
            case .rsa: return "ssh-rsa"
            }
        }
    }

    var keychainTag: String { "sshkey.\(id.uuidString)" }
    var passphraseTag: String { "sshpass.\(id.uuidString)" }
}
