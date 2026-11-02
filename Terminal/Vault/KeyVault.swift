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
    case unsupportedType
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
            guard Keychain.save(privateKey.rawRepresentation, tag: key.keychainTag, biometry: biometry) == errSecSuccess else {
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
            guard Keychain.save(privateKey.dataRepresentation, tag: key.keychainTag, biometry: false) == errSecSuccess else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = ecdsaPublicLine(curve: "nistp256", point: privateKey.publicKey.x963Representation)
            key.inSecureEnclave = true

        case .p256:
            let privateKey = Crypto.P256.Signing.PrivateKey()
            guard Keychain.save(privateKey.rawRepresentation, tag: key.keychainTag, biometry: biometry) == errSecSuccess else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = ecdsaPublicLine(curve: "nistp256", point: privateKey.publicKey.x963Representation)

        case .p384:
            let privateKey = Crypto.P384.Signing.PrivateKey()
            guard Keychain.save(privateKey.rawRepresentation, tag: key.keychainTag, biometry: biometry) == errSecSuccess else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = ecdsaPublicLine(curve: "nistp384", point: privateKey.publicKey.x963Representation)

        case .p521:
            let privateKey = Crypto.P521.Signing.PrivateKey()
            guard Keychain.save(privateKey.rawRepresentation, tag: key.keychainTag, biometry: biometry) == errSecSuccess else {
                throw KeyVaultError.keyMaterialMissing
            }
            key.publicKeyOpenSSH = ecdsaPublicLine(curve: "nistp521", point: privateKey.publicKey.x963Representation)

        case .rsa:
            throw KeyVaultError.unsupportedType
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
        guard Keychain.save(parsed.privateMaterial, tag: key.keychainTag, biometry: false) == errSecSuccess else {
            throw KeyVaultError.keyMaterialMissing
        }
        return key
    }

    // MARK: - Authentication

    /// Produces a Citadel authentication method. May trigger Face ID for
    /// biometry-protected keys.
    ///
    /// Secure Enclave keys with `.userPresence` ACL prompt *at signing
    /// time* — deep inside the NIO handshake, off the main actor, where
    /// the system can't show UI and the prompt fails. Authenticate here
    /// first and grant a short reuse window so the in-handshake sign
    /// operation reuses it silently.
    static func authenticationMethod(
        for storedKey: StoredSSHKey,
        username: String,
        context: LAContext? = nil
    ) async throws -> SSHAuthenticationMethod {
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
            if storedKey.requiresBiometry {
                let authContext = LAContext()
                authContext.touchIDAuthenticationAllowableReuseDuration = 30
                guard (try? await authContext.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: storedKey.name
                )) == true else {
                    throw KeyVaultError.biometricDenied
                }
            }
            guard let raw = Keychain.load(tag: storedKey.keychainTag, context: context) else {
                throw KeyVaultError.keyMaterialMissing
            }
            let seKey = try CryptoKit.SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: raw)
            return .custom(SecureEnclaveAuthDelegate(username: username, key: seKey))

        case .rsa:
            throw KeyVaultError.keyMaterialMissing
        }
    }

    // MARK: - Export

    /// Writes an openssh-key-v1 private key PEM. `passphrase` encrypts
    /// with bcrypt-kdf + aes256-ctr (same format ssh-keygen produces);
    /// empty/nil exports unprotected.
    static func exportPrivateKey(_ key: StoredSSHKey, passphrase: String? = nil) throws -> String {
        switch key.type {
        case .ed25519:
            guard let raw = Keychain.load(tag: key.keychainTag) else {
                throw KeyVaultError.keyMaterialMissing
            }
            let privateKey = try Crypto.Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            let pub = privateKey.publicKey.rawRepresentation
            var pubBlob = SSHWireWriter()
            pubBlob.writeText("ssh-ed25519")
            pubBlob.writeString(pub)
            var inner = SSHWireWriter()
            let check = UInt32.random(in: .min ... .max)
            inner.writeUInt32(check)
            inner.writeUInt32(check)
            inner.writeText("ssh-ed25519")
            inner.writeString(pub)
            inner.writeString(raw + pub)
            inner.writeText(key.name)
            return try wrapKeyV1(publicBlob: pubBlob.data, inner: inner.data, passphrase: passphrase)

        case .p256, .p384, .p521:
            guard let raw = Keychain.load(tag: key.keychainTag) else {
                throw KeyVaultError.keyMaterialMissing
            }
            let (curve, typeName, point) = try ecdsaParts(type: key.type, scalar: raw)
            var pubBlob = SSHWireWriter()
            pubBlob.writeText(typeName)
            pubBlob.writeText(curve)
            pubBlob.writeString(point)
            var inner = SSHWireWriter()
            let check = UInt32.random(in: .min ... .max)
            inner.writeUInt32(check)
            inner.writeUInt32(check)
            inner.writeText(typeName)
            inner.writeText(curve)
            inner.writeString(point)
            inner.writeString(mpint(raw))
            inner.writeText(key.name)
            return try wrapKeyV1(publicBlob: pubBlob.data, inner: inner.data, passphrase: passphrase)

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

    /// Curve name, SSH type name and public point for an ecdsa scalar.
    private static func ecdsaParts(type: StoredSSHKey.KeyType, scalar: Data) throws -> (String, String, Data) {
        switch type {
        case .p256:
            let k = try CryptoKit.P256.Signing.PrivateKey(rawRepresentation: scalar)
            return ("nistp256", "ecdsa-sha2-nistp256", k.publicKey.x963Representation)
        case .p384:
            let k = try CryptoKit.P384.Signing.PrivateKey(rawRepresentation: scalar)
            return ("nistp384", "ecdsa-sha2-nistp384", k.publicKey.x963Representation)
        case .p521:
            let k = try CryptoKit.P521.Signing.PrivateKey(rawRepresentation: scalar)
            return ("nistp521", "ecdsa-sha2-nistp521", k.publicKey.x963Representation)
        default:
            throw KeyVaultError.cannotExport
        }
    }

    /// Pads `inner` to the cipher block size and wraps both sections into
    /// an openssh-key-v1 PEM, optionally bcrypt-kdf + aes256-ctr encrypted.
    private static func wrapKeyV1(publicBlob: Data, inner: Data, passphrase: String?) throws -> String {
        let encrypt = passphrase.map { !$0.isEmpty } ?? false
        let blockSize = encrypt ? 16 : 8
        var section = inner
        let padCount = blockSize - (section.count % blockSize)
        for i in 1...padCount {
            section.append(UInt8(i))
        }

        let cipher: String
        let kdfName: String
        var kdfOptions = Data()
        if encrypt, let passphrase {
            var salt = Data(count: 16)
            let saltStatus = salt.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
            }
            guard saltStatus == errSecSuccess else { throw KeyVaultError.cannotExport }
            var kdf = SSHWireWriter()
            kdf.writeString(salt)
            kdf.writeUInt32(100)
            kdfOptions = kdf.data
            let derived = BCryptPBKDF.pbkdf(
                password: Data(passphrase.utf8),
                salt: salt,
                keyLength: 48,
                rounds: 100
            )
            section = try AESCTR.crypt(key: derived.prefix(32), iv: derived.suffix(16), data: section)
            cipher = "aes256-ctr"
            kdfName = "bcrypt"
        } else {
            cipher = "none"
            kdfName = "none"
        }

        var outer = Data("openssh-key-v1\0".utf8)
        var w = SSHWireWriter()
        w.writeText(cipher)
        w.writeText(kdfName)
        w.writeString(kdfOptions)
        w.writeUInt32(1)
        w.writeString(publicBlob)
        w.writeString(section)
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
