import XCTest
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
}
