import XCTest
import CryptoKit
@testable import Terminal

/// AES-CTR NIST vector + real ssh-keygen fixtures (bcrypt KDF covered
/// implicitly — decrypting a real key IS the strongest interop test).
final class CryptoAndKeyParserTests: XCTestCase {

    // MARK: - AES-CTR (NIST SP 800-38A F.5.5, CTR-AES256)

    func testAESCTRNISTVector() throws {
        let key = Data([
            0x60, 0x3d, 0xeb, 0x10, 0x15, 0xca, 0x71, 0xbe,
            0x2b, 0x73, 0xae, 0xf0, 0x85, 0x7d, 0x77, 0x81,
            0x1f, 0x35, 0x2c, 0x07, 0x3b, 0x61, 0x08, 0xd7,
            0x2d, 0x98, 0x10, 0xa3, 0x09, 0x14, 0xdf, 0xf4
        ])
        let iv = Data([
            0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7,
            0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff
        ])
        let plain = Data([
            0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
            0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a
        ])
        let expected = Data([
            0x60, 0x1e, 0xc3, 0x13, 0x77, 0x57, 0x89, 0xa5,
            0xb7, 0xa7, 0xf5, 0x04, 0xbb, 0xf3, 0xd2, 0x28
        ])
        let ct = try AESCTR.crypt(key: key, iv: iv, data: plain)
        XCTAssertEqual(ct, expected)
        // CTR is symmetric — decrypting returns the plaintext.
        XCTAssertEqual(try AESCTR.crypt(key: key, iv: iv, data: ct), plain)
    }

    // MARK: - OpenSSH import (fixtures produced by real ssh-keygen)

    /// `ssh-keygen -t ed25519 -N "" -C test-ed25519`
    private let ed25519PEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACBFaX3DW3og9YGOUvy181oSEyB0arOu6KyO85Jmn+wYWAAAAJAMEzr6DBM6
        +gAAAAtzc2gtZWQyNTUxOQAAACBFaX3DW3og9YGOUvy181oSEyB0arOu6KyO85Jmn+wYWA
        AAAEAPmcHBr4JsZ+lfK1xefrPGrmXtORs4Xk9tpDzgrjhFlEVpfcNbeiD1gY5S/LXzWhIT
        IHRqs67orI7zkmaf7BhYAAAADHRlc3QtZWQyNTUxOQE=
        -----END OPENSSH PRIVATE KEY-----
        """
    private let ed25519PublicLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEVpfcNbeiD1gY5S/LXzWhITIHRqs67orI7zkmaf7BhY"

    /// `ssh-keygen -t ed25519 -N testpass123 -C test-enc`
    private let encryptedPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDmtJY9sL
        8vq9pXtGxMELvpAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIA4rZTzXG8+YOcOG
        1Yb+yM29JQsPoCpWh8H8dC0ZXh6AAAAAkOII+QXk5eQwv5VOCnI2tg2g7p3/Aefj0oOfnT
        M0RzNA9iI0bWr3+20eaUzmMnQ43IMBptbwddFMNnUNALq5NblwTN3lIwHb96IPUQ9LQEeJ
        oCBSFIDy28zBU5XdyFs3/a8azr3+jXcyxnriZQmrApyXcbyxAkddCz3DyXII/U/WIcmAyJ
        OwnnAolZydadwveg==
        -----END OPENSSH PRIVATE KEY-----
        """
    private let encryptedPublicLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA4rZTzXG8+YOcOG1Yb+yM29JQsPoCpWh8H8dC0ZXh6A"

    /// `ssh-keygen -t ecdsa -b 256 -N "" -C test-p256`
    private let p256PEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQS6V5vQsKXVaNkYZTwma3ITkwh6MatF
        7GBLZXd4XEfiemaECCcIc9FV0AtDChGkdh1x/AqoI1etf1qrJRHs4XN2AAAAqL4sVdi+LF
        XYAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLpXm9CwpdVo2Rhl
        PCZrchOTCHoxq0XsYEtld3hcR+J6ZoQIJwhz0VXQC0MKEaR2HXH8CqgjV61/WqslEezhc3
        YAAAAhAOWZ7fiid7rUxR+914ey9cbKL4l62gToZYCVAdUPAsw7AAAACXRlc3QtcDI1NgEC
        AwQFBg==
        -----END OPENSSH PRIVATE KEY-----
        """
    private let p256PublicLine =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLpXm9CwpdVo2RhlPCZrchOTCHoxq0XsYEtld3hcR+J6ZoQIJwhz0VXQC0MKEaR2HXH8CqgjV61/WqslEezhc3Y="

    func testEd25519Fixture() throws {
        let parsed = try OpenSSHKeyParser.parse(ed25519PEM, passphrase: nil)
        XCTAssertEqual(parsed.type, .ed25519)
        XCTAssertEqual(parsed.privateMaterial.count, 32)
        XCTAssertEqual(parsed.publicKeyLine, ed25519PublicLine)
        XCTAssertEqual(parsed.comment, "test-ed25519")
    }

    func testEncryptedFixtureNeedsPassphrase() {
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(encryptedPEM, passphrase: nil)) { error in
            XCTAssertEqual(error as? SSHKeyImportError, .encryptedNeedsPassphrase)
        }
    }

    func testEncryptedFixtureWrongPassphrase() {
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(encryptedPEM, passphrase: "nope")) { error in
            XCTAssertEqual(error as? SSHKeyImportError, .wrongPassphrase)
        }
    }

    func testEncryptedFixtureDecryptsWithRealPassphrase() throws {
        let parsed = try OpenSSHKeyParser.parse(encryptedPEM, passphrase: "testpass123")
        XCTAssertEqual(parsed.type, .ed25519)
        XCTAssertEqual(parsed.publicKeyLine, encryptedPublicLine)
        XCTAssertEqual(parsed.comment, "test-enc")
    }

    func testP256Fixture() throws {
        let parsed = try OpenSSHKeyParser.parse(p256PEM, passphrase: nil)
        XCTAssertEqual(parsed.type, .p256)
        XCTAssertEqual(parsed.privateMaterial.count, 32)
        XCTAssertEqual(parsed.publicKeyLine, p256PublicLine)
    }

    // MARK: - Generated public key lines

    /// KeyVault's ed25519 generation path: ed25519PublicKeyBlob already
    /// produces the complete wire blob, so the line must be single-
    /// encoded — "type base64(blob)", not base64 of a re-wrapped blob.
    /// authorized_keys rejects the doubly-wrapped form.
    func testGeneratedEd25519PublicLineIsSingleEncoded() throws {
        let privateKey = CryptoKit.Curve25519.Signing.PrivateKey()
        let blob = SSHWireWriter.ed25519PublicKeyBlob(privateKey.publicKey.rawRepresentation)
        let line = SSHWireWriter.publicKeyLine(type: "ssh-ed25519", blob: blob)

        XCTAssertTrue(line.hasPrefix("ssh-ed25519 "))
        let parts = line.split(separator: " ")
        XCTAssertEqual(parts.count, 2)
        let decoded = try XCTUnwrap(Data(base64Encoded: String(parts[1])))
        XCTAssertEqual(decoded, blob)

        // And the blob itself is wire-decodable: string type + string key.
        var reader = SSHWireReader(decoded)
        XCTAssertEqual(try reader.readText(), "ssh-ed25519")
        XCTAssertEqual(try reader.readString(), privateKey.publicKey.rawRepresentation)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testTamperedFixtureRejected() throws {
        // Flip a byte deep inside the private section: checkint no
        // longer matches — parser must refuse, not import a broken key.
        var blob = Data(base64Encoded: ed25519PEM
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression))!
        blob[blob.count - 20] ^= 0xFF
        let tampered = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + blob.base64EncodedString(options: .lineLength64Characters)
            + "\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(tampered, passphrase: nil))
    }

    func testNonOpenSSHInputRejected() {
        XCTAssertThrowsError(try OpenSSHKeyParser.parse("hello world", passphrase: nil)) { error in
            XCTAssertEqual(error as? SSHKeyImportError, .invalidFormat)
        }
    }

    // MARK: - Export → parse roundtrip

    /// Anything our writer emits must parse back through our reader —
    /// and through real OpenSSH tooling by construction of the format.
    func testExportedKeyParsesBack() throws {
        var key = StoredSSHKey()
        key.name = "roundtrip"
        // Stash a known private key: reuse the fixture's material.
        let parsed = try OpenSSHKeyParser.parse(ed25519PEM, passphrase: nil)
        key.type = .ed25519
        key.publicKeyOpenSSH = parsed.publicKeyLine
        // Keychain hop is what makes this an integration test — on a
        // simulator/device it exercises the real SecItem path.
        XCTAssertEqual(Keychain.save(parsed.privateMaterial, tag: key.keychainTag, biometry: false), errSecSuccess)
        defer { Keychain.delete(tag: key.keychainTag) }

        let pem = try KeyVault.exportPrivateKey(key)
        let reParsed = try OpenSSHKeyParser.parse(pem, passphrase: nil)
        XCTAssertEqual(reParsed.privateMaterial, parsed.privateMaterial)
        XCTAssertEqual(reParsed.publicKeyLine, parsed.publicKeyLine)
    }

    func testEncryptedExportParsesBack() throws {
        var key = StoredSSHKey()
        key.name = "enc-roundtrip"
        let parsed = try OpenSSHKeyParser.parse(p256PEM, passphrase: nil)
        key.type = .p256
        key.publicKeyOpenSSH = parsed.publicKeyLine
        XCTAssertEqual(Keychain.save(parsed.privateMaterial, tag: key.keychainTag, biometry: false), errSecSuccess)
        defer { Keychain.delete(tag: key.keychainTag) }

        let pem = try KeyVault.exportPrivateKey(key, passphrase: "export-pass")
        XCTAssertTrue(OpenSSHKeyParser.isEncrypted(pem))
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: "wrong"))
        let reParsed = try OpenSSHKeyParser.parse(pem, passphrase: "export-pass")
        XCTAssertEqual(reParsed.privateMaterial, parsed.privateMaterial)
        XCTAssertEqual(reParsed.publicKeyLine, parsed.publicKeyLine)
    }

    // MARK: - Crafted-key builders

    private func blobData(_ pem: String) -> Data {
        Data(base64Encoded: pem
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression))!
    }

    private func reencode(_ blob: Data) -> String {
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + blob.base64EncodedString(options: .lineLength64Characters)
            + "\n-----END OPENSSH PRIVATE KEY-----"
    }

    /// Builds an unencrypted openssh-key-v1 ed25519 PEM with every
    /// public-key position caller-controlled — each substitution is
    /// tested independently.
    private func craftedEd25519PEM(
        seed: Data,
        embedded: Data,
        outer: Data,
        tail: Data,
        commentBytes: Data? = nil,
        padLength: Int? = nil,
        blobSuffix: Data = Data(),
        outerSuffix: Data = Data()
    ) -> String {
        var pub = SSHWireWriter()
        pub.writeText("ssh-ed25519")
        pub.writeString(outer)
        var pubData = pub.data
        pubData.append(blobSuffix)

        var inner = SSHWireWriter()
        inner.writeUInt32(0xDEADBEEF)
        inner.writeUInt32(0xDEADBEEF)
        inner.writeText("ssh-ed25519")
        inner.writeString(embedded)
        inner.writeString(seed + tail)
        if let commentBytes {
            inner.writeString(commentBytes)
        } else {
            // The comment doubles as alignment filler so a custom
            // padLength stays block-aligned.
            let filler = (8 - ((inner.data.count + 4) % 8)) % 8
            inner.writeText(String(repeating: "c", count: filler))
        }
        var section = inner.data
        let pad = padLength ?? (8 - (section.count % 8))
        for i in 0..<pad { section.append(UInt8(i + 1)) }

        var w = SSHWireWriter()
        w.writeText("none")
        w.writeText("none")
        w.writeString(Data())
        w.writeUInt32(1)
        w.writeString(pubData)
        w.writeString(section)
        var outerData = Data("openssh-key-v1\0".utf8)
        outerData.append(w.data)
        outerData.append(outerSuffix)
        return reencode(outerData)
    }

    /// Builds an unencrypted openssh-key-v1 ECDSA PEM — the private
    /// section's `curve` and the declared `typeName` can disagree.
    private func craftedECDSAPEM(typeName: String, curve: String) -> String {
        var pub = SSHWireWriter()
        pub.writeText(typeName)
        pub.writeText(curve)
        pub.writeString(Data(repeating: 4, count: 65))

        var inner = SSHWireWriter()
        inner.writeUInt32(7)
        inner.writeUInt32(7)
        inner.writeText(typeName)
        inner.writeText(curve)
        inner.writeString(Data(repeating: 4, count: 65))
        inner.writeString(Data(repeating: 1, count: 32))
        inner.writeText("t")
        var section = inner.data
        let pad = 8 - (section.count % 8)
        for i in 0..<pad { section.append(UInt8(i + 1)) }

        var w = SSHWireWriter()
        w.writeText("none")
        w.writeText("none")
        w.writeString(Data())
        w.writeUInt32(1)
        w.writeString(pub.data)
        w.writeString(section)
        var outerData = Data("openssh-key-v1\0".utf8)
        outerData.append(w.data)
        return reencode(outerData)
    }

    // MARK: - ed25519 pair-check substitutions (#19)

    /// Control: a self-consistent crafted key still parses.
    func testEd25519CraftedControlParses() throws {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let pub = a.publicKey.rawRepresentation
        let pem = craftedEd25519PEM(seed: a.rawRepresentation, embedded: pub, outer: pub, tail: pub)
        let parsed = try OpenSSHKeyParser.parse(pem, passphrase: nil)
        XCTAssertEqual(parsed.type, .ed25519)
        XCTAssertEqual(parsed.privateMaterial, a.rawRepresentation)
    }

    /// embedded = B while outer/tail/seed are A — substitution in the
    /// private section's embedded public.
    func testEd25519EmbeddedSubstitutionRejected() {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let b = CryptoKit.Curve25519.Signing.PrivateKey()
        let pem = craftedEd25519PEM(
            seed: a.rawRepresentation,
            embedded: b.publicKey.rawRepresentation,
            outer: a.publicKey.rawRepresentation,
            tail: a.publicKey.rawRepresentation
        )
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    /// outer = B while embedded/tail/seed are A — substitution in the
    /// outer public blob.
    func testEd25519OuterSubstitutionRejected() {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let b = CryptoKit.Curve25519.Signing.PrivateKey()
        let pem = craftedEd25519PEM(
            seed: a.rawRepresentation,
            embedded: a.publicKey.rawRepresentation,
            outer: b.publicKey.rawRepresentation,
            tail: a.publicKey.rawRepresentation
        )
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    /// tail = B while embedded/outer/seed are A — substitution in the
    /// private blob's trailing public half.
    func testEd25519TailSubstitutionRejected() {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let b = CryptoKit.Curve25519.Signing.PrivateKey()
        let pem = craftedEd25519PEM(
            seed: a.rawRepresentation,
            embedded: a.publicKey.rawRepresentation,
            outer: a.publicKey.rawRepresentation,
            tail: b.publicKey.rawRepresentation
        )
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    /// THE gap: every public-key position consistently claims B while
    /// the seed is A — embedded==outer used to pass, and tail==derived
    /// only compared tail to the (mismatched) seed, so this chimera
    /// imported. Now embeddedPub==derivedPub catches it.
    func testEd25519SeedAPublicBChimeraRejected() {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let b = CryptoKit.Curve25519.Signing.PrivateKey()
        let pubB = b.publicKey.rawRepresentation
        let pem = craftedEd25519PEM(
            seed: a.rawRepresentation,
            embedded: pubB,
            outer: pubB,
            tail: pubB
        )
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    // MARK: - Strict openssh-key-v1 validation (#20)

    func testTrailingOuterBytesRejected() {
        var blob = blobData(ed25519PEM)
        blob.append(0x00)
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(reencode(blob), passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    func testTrailingPublicBlobBytesRejected() {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let pub = a.publicKey.rawRepresentation
        let pem = craftedEd25519PEM(
            seed: a.rawRepresentation, embedded: pub, outer: pub, tail: pub,
            blobSuffix: Data([0xAA])
        )
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    func testEmptyPaddingRejected() {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let pub = a.publicKey.rawRepresentation
        let pem = craftedEd25519PEM(
            seed: a.rawRepresentation, embedded: pub, outer: pub, tail: pub,
            padLength: 0
        )
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    func testOverlongPaddingRejected() {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let pub = a.publicKey.rawRepresentation
        // 16 correctly-incrementing pad bytes under cipher "none"
        // (block size 8): valid bytes, invalid length.
        let pem = craftedEd25519PEM(
            seed: a.rawRepresentation, embedded: pub, outer: pub, tail: pub,
            padLength: 16
        )
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    func testCorruptPaddingByteRejected() {
        var blob = blobData(ed25519PEM)
        // The private section is the last field — its last byte is a
        // padding byte. Flip it.
        blob[blob.count - 1] ^= 0xFF
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(reencode(blob), passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    func testKeyTypeCurveMismatchRejected() {
        // Type says nistp256, embedded curve field says nistp384.
        let pem = craftedECDSAPEM(typeName: "ecdsa-sha2-nistp256", curve: "nistp384")
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    func testNonUTF8CommentRejected() {
        let a = CryptoKit.Curve25519.Signing.PrivateKey()
        let pub = a.publicKey.rawRepresentation
        let pem = craftedEd25519PEM(
            seed: a.rawRepresentation, embedded: pub, outer: pub, tail: pub,
            commentBytes: Data([0xFF, 0xFE])
        )
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .corrupt)
        }
    }

    func testOversizedPEMRejectedBeforeDecode() {
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + String(repeating: "A", count: 129 * 1024)
            + "\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .invalidFormat)
        }
    }

    // MARK: - Cancellable bcrypt KDF (#18/#20)

    func testBCryptKDFIsCancellable() {
        XCTAssertThrowsError(try BCryptPBKDF.pbkdf(
            password: Data("p".utf8), salt: Data("s".utf8),
            keyLength: 48, rounds: 16, isCancelled: { true })
        ) {
            XCTAssertTrue($0 is CancellationError)
        }
        // An un-cancelled derivation still produces bytes.
        XCTAssertEqual(
            BCryptPBKDF.pbkdf(password: Data("p".utf8), salt: Data("s".utf8), keyLength: 48, rounds: 1).count,
            48
        )
    }

    // MARK: - Keychain OSStatus paths (#6)

    /// Exercises the real SecItem statuses on the simulator keychain:
    /// absent → errSecItemNotFound, saved → errSecSuccess, and delete
    /// reports its own status instead of void.
    func testKeychainLoadStatusAndDeleteStatus() {
        let tag = "test.\(UUID().uuidString)"
        var result = Keychain.loadWithStatus(tag: tag)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.status, errSecItemNotFound)

        XCTAssertEqual(Keychain.save(Data("s".utf8), tag: tag), errSecSuccess)
        defer { Keychain.delete(tag) }

        result = Keychain.loadWithStatus(tag: tag)
        XCTAssertEqual(result.status, errSecSuccess)
        XCTAssertEqual(result.data, Data("s".utf8))

        XCTAssertEqual(Keychain.delete(tag), errSecSuccess)
        XCTAssertEqual(Keychain.loadWithStatus(tag: tag).status, errSecItemNotFound)
    }
}
