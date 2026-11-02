import XCTest
@testable import Terminal

final class QuickConnectParserTests: XCTestCase {
    private func parse(_ s: String) -> QuickConnectParser.Result? {
        QuickConnectParser.parse(s, profiles: [])
    }

    func testBareHost() {
        let r = parse("example.com")
        XCTAssertEqual(r?.profile.host, "example.com")
        XCTAssertEqual(r?.profile.port, 22)
        XCTAssertEqual(r?.profile.username, "root")
    }

    func testUserAtHost() {
        let r = parse("ubuntu@example.com")
        XCTAssertEqual(r?.profile.username, "ubuntu")
        XCTAssertEqual(r?.profile.host, "example.com")
    }

    func testHostColonPort() {
        let r = parse("host.local:2222")
        XCTAssertEqual(r?.profile.host, "host.local")
        XCTAssertEqual(r?.profile.port, 2222)
    }

    func testUserHostPort() {
        let r = parse("deploy@host.local:2222")
        XCTAssertEqual(r?.profile.username, "deploy")
        XCTAssertEqual(r?.profile.host, "host.local")
        XCTAssertEqual(r?.profile.port, 2222)
    }

    func testUserPasswordInline() {
        let r = parse("root:s3cret@host.local")
        XCTAssertEqual(r?.profile.username, "root")
        XCTAssertEqual(r?.profile.host, "host.local")
        XCTAssertEqual(r?.password, "s3cret")
    }

    func testSSHCommandForm() {
        let r = parse("ssh -p 2200 ubuntu@example.com")
        XCTAssertEqual(r?.profile.port, 2200)
        XCTAssertEqual(r?.profile.username, "ubuntu")
        XCTAssertEqual(r?.profile.host, "example.com")
    }

    func testSSHCompactFlag() {
        let r = parse("ssh -p2200 ubuntu@example.com")
        XCTAssertEqual(r?.profile.port, 2200)
    }

    func testSSHURL() {
        let r = parse("ssh://ubuntu@example.com:2222")
        XCTAssertEqual(r?.profile.username, "ubuntu")
        XCTAssertEqual(r?.profile.host, "example.com")
        XCTAssertEqual(r?.profile.port, 2222)
    }

    func testSSHURLWithPassword() {
        let r = parse("ssh://user:pass%20word@example.com")
        XCTAssertEqual(r?.password, "pass word")
    }

    func testBracketedIPv6WithPort() {
        let r = parse("[::1]:2222")
        XCTAssertEqual(r?.profile.host, "::1")
        XCTAssertEqual(r?.profile.port, 2222)
    }

    func testBracketedIPv6Bare() {
        let r = parse("[fe80::1]")
        XCTAssertEqual(r?.profile.host, "fe80::1")
        XCTAssertEqual(r?.profile.port, 22)
    }

    func testBareIPv6() {
        let r = parse("::1")
        XCTAssertEqual(r?.profile.host, "::1")
        XCTAssertEqual(r?.profile.port, 22)
    }

    func testIPv6WithUser() {
        let r = parse("root@[2001:db8::5]:2200")
        XCTAssertEqual(r?.profile.username, "root")
        XCTAssertEqual(r?.profile.host, "2001:db8::5")
        XCTAssertEqual(r?.profile.port, 2200)
    }

    func testRejectsUnknownFlag() {
        XCTAssertNil(parse("ssh -v ubuntu@example.com"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   "))
    }

    func testRejectsBadPort() {
        XCTAssertNil(parse("host:99999"))
        XCTAssertNil(parse("host:abc"))
    }

    func testLastUsedUsernameWins() {
        var p = ServerProfile()
        p.username = "deploy"
        p.lastConnected = Date()
        let r = QuickConnectParser.parse("example.com", profiles: [p])
        XCTAssertEqual(r?.profile.username, "deploy")
    }
}
