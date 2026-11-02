import Foundation
import CryptoKit
import Crypto
import Citadel
import NIO
import NIOSSH
import LocalAuthentication

enum KeyVaultError: Error {
    case keyMaterialMissing
    case secureEnclaveUnavailable
    case cannotExport
    case biometricDenied
}

/// Creates, stores and produces Citadel auth methods for SSH keys.
/// Private material lives only in the Keychain (ThisDeviceOnly).
enum KeyVault {

    // MARK: - Generation

    @MainActor
    static func generate(_ type: StoredSSHKey.KeyType, name: String, biometry: Bool) throws -> StoredSSHKey {
        var key = StoredSSHKey()
        key.name = name
        key.type = type

        switch type {
        case .ed25519:
            let privateKey = Crypto.Curve25519.Signing.PrivateKey()
            guard Keychain.save(privateKey.rawRepresentation, tag: key.keychainTag, biometry: biometry) else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = SSHWireWriter.publicKeyLine(
                type: "ssh-ed25519",
                blob: SSHWireWriter.ed25519PublicKeyBlob(privateKey.publicKey.rawRepresentation)
            )

        case .secureEnclaveP256:
            guard SecureEnclave.isAvailable else { throw KeyVaultError.secureEnclaveUnavailable }
            guard let acl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                biometry ? [.privateKeyUsage, .userPresence] : .privateKeyUsage,
                nil
            ) else { throw KeyVaultError.secureEnclaveUnavailable }
            let privateKey = try CryptoKit.SecureEnclave.P256.Signing.PrivateKey(accessControl: acl)
            guard Keychain.save(privateKey.dataRepresentation, tag: key.keychainTag, biometry: false) else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = ecdsaPublicLine(curve: "nistp256", point: privateKey.publicKey.x963Representation)
            key.inSecureEnclave = true

        case .p256:
            let privateKey = Crypto.P256.Signing.PrivateKey()
            guard Keychain.save(privateKey.rawRepresentation, tag: key.keychainTag, biometry: biometry) else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = ecdsaPublicLine(curve: "nistp256", point: privateKey.publicKey.x963Representation)

        case .p384:
            let privateKey = Crypto.P384.Signing.PrivateKey()
            guard Keychain.save(privateKey.rawRepresentation, tag: key.keychainTag, biometry: biometry) else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = ecdsaPublicLine(curve: "nistp384", point: privateKey.publicKey.x963Representation)

        case .p521:
            let privateKey = Crypto.P521.Signing.PrivateKey()
            guard Keychain.save(privateKey.rawRepresentation, tag: key.keychainTag, biometry: biometry) else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = ecdsaPublicLine(curve: "nistp521", point: privateKey.publicKey.x963Representation)

        case .rsa:
            break // generation unsupported — use ed25519
        }

        key.requiresBiometry = biometry
        return key
    }

    // MARK: - Import

    static func `import`(pem: String, name: String, passphrase: String?) throws -> StoredSSHKey {
        let parsed = try OpenSSHKeyParser.parse(pem, passphrase: passphrase)
        var key = StoredSSHKey()
        key.name = name.isEmpty ? (parsed.comment.isEmpty ? "key" : parsed.comment) : name
        key.type = parsed.type
        key.publicKeyOpenSSH = parsed.publicKeyLine
        key.encryptedImport = OpenSSHKeyParser.isEncrypted(pem)
        guard Keychain.save(parsed.privateMaterial, tag: key.keychainTag, biometry: false) else {
            throw KeyVaultError.keyMaterialMissing
        }
        return key
    }

    // MARK: - Authentication

    /// Produces a Citadel authentication method. May trigger Face ID for
    /// biometry-protected keys.
    static func authenticationMethod(
        for storedKey: StoredSSHKey,
        username: String,
        context: LAContext? = nil
    ) throws -> SSHAuthenticationMethod {
        switch storedKey.type {
        case .ed25519:
            guard let raw = Keychain.load(tag: storedKey.keychainTag, context: context) else {
                throw KeyVaultError.keyMaterialMissing
            }
            let privateKey = try Crypto.Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            return .ed25519(username: username, privateKey: privateKey)

        case .p256:
            guard let raw = Keychain.load(tag: storedKey.keychainTag, context: context) else {
                throw KeyVaultError.keyMaterialMissing
            }
            return .p256(username: username, privateKey: try Crypto.P256.Signing.PrivateKey(rawRepresentation: raw))

        case .p384:
            guard let raw = Keychain.load(tag: storedKey.keychainTag, context: context) else {
                throw KeyVaultError.keyMaterialMissing
            }
            return .p384(username: username, privateKey: try Crypto.P384.Signing.PrivateKey(rawRepresentation: raw))

        case .p521:
            guard let raw = Keychain.load(tag: storedKey.keychainTag, context: context) else {
                throw KeyVaultError.keyMaterialMissing
            }
            return .p521(username: username, privateKey: try Crypto.P521.Signing.PrivateKey(rawRepresentation: raw))

        case .secureEnclaveP256:
            guard let raw = Keychain.load(tag: storedKey.keychainTag) else {
                throw KeyVaultError.keyMaterialMissing
            }
            let seKey = try CryptoKit.SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: raw)
            return .custom(SecureEnclaveAuthDelegate(username: username, key: seKey))

        case .rsa:
            throw KeyVaultError.keyMaterialMissing
        }
    }

    // MARK: - Export

    static func exportPrivateKey(_ key: StoredSSHKey) throws -> String {
        switch key.type {
        case .ed25519:
            guard let raw = Keychain.load(tag: key.keychainTag) else {
                throw KeyVaultError.keyMaterialMissing
            }
            let privateKey = try Crypto.Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            return privateKey.makeSSHRepresentation(comment: key.name)

        case .p256, .p384, .p521:
            guard let raw = Keychain.load(tag: key.keychainTag) else {
                throw KeyVaultError.keyMaterialMissing
            }
            return try exportECDSAPrivateKey(type: key.type, scalar: raw, comment: key.name)

        case .secureEnclaveP256, .rsa:
            throw KeyVaultError.cannotExport
        }
    }

    // MARK: - Public key helpers

    private static func ecdsaPublicLine(curve: String, point: Data) -> String {
        SSHWireWriter.publicKeyLine(
            type: "ecdsa-sha2-\(curve)",
            blob: SSHWireWriter.ecdsaPublicKeyBlob(curve: curve, point: point)
        )
    }

    /// Writes an openssh-key-v1 unencrypted private key for ecdsa keys.
    private static func exportECDSAPrivateKey(type: StoredSSHKey.KeyType, scalar: Data, comment: String) throws -> String {
        let (curve, typeName): (String, String)
        switch type {
        case .p256: (curve, typeName) = ("nistp256", "ecdsa-sha2-nistp256")
        case .p384: (curve, typeName) = ("nistp384", "ecdsa-sha2-nistp384")
        case .p521: (curve, typeName) = ("nistp521", "ecdsa-sha2-nistp521")
        default: throw KeyVaultError.cannotExport
        }
        let point: Data
        switch type {
        case .p256:
            let k = try CryptoKit.P256.Signing.PrivateKey(rawRepresentation: scalar)
            point = k.publicKey.x963Representation
        case .p384:
            let k = try CryptoKit.P384.Signing.PrivateKey(rawRepresentation: scalar)
            point = k.publicKey.x963Representation
        case .p521:
            let k = try CryptoKit.P521.Signing.PrivateKey(rawRepresentation: scalar)
            point = k.publicKey.x963Representation
        default: throw KeyVaultError.cannotExport
        }

        var publicBlob = SSHWireWriter()
        publicBlob.writeText(typeName)
        publicBlob.writeText(curve)
        publicBlob.writeString(point)

        var inner = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        inner.writeUInt32(check)
        inner.writeUInt32(check)
        inner.writeText(typeName)
        inner.writeText(curve)
        inner.writeString(point)
        inner.writeString(mpint(scalar))
        inner.writeText(comment)
        // pad to block size 8 with 1,2,3...
        let padCount = 8 - (inner.data.count % 8)
        for i in 1...padCount {
            inner.data.append(UInt8(i))
        }

        var outer = Data("openssh-key-v1\0".utf8)
        var w = SSHWireWriter()
        w.writeText("none")
        w.writeText("none")
        w.writeString(Data())
        w.writeUInt32(1)
        w.writeString(publicBlob.data)
        w.writeString(inner.data)
        outer.append(w.data)

        let b64 = outer.base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(b64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private static func mpint(_ data: Data) -> Data {
        var d = data
        while d.count > 1 && d.first == 0 { d = d.dropFirst() }
        if d.first.map({ $0 & 0x80 != 0 }) == true {
            d = Data([0]) + d
        }
        return d
    }
}

/// User-auth delegate that offers a Secure Enclave P-256 key.
struct SecureEnclaveAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let key: CryptoKit.SecureEnclave.P256.Signing.PrivateKey

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHClientError.unsupportedPrivateKeyAuthentication)
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: .init(secureEnclaveP256Key: key)))
        ))
    }
}
