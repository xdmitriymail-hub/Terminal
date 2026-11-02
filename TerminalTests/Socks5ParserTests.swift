import XCTest
@testable import Terminal

final class Socks5ParserTests: XCTestCase {
    func testIPv4() {
        // 127.0.0.1 : 8080
        let payload = Data([127, 0, 0, 1, 0x1F, 0x90])
        let r = Socks5.parseRequest(atyp: 0x01, payload: payload)
        XCTAssertEqual(r, .init(host: "127.0.0.1", port: 8080))
    }

    func testIPv4RejectsShortPayload() {
        XCTAssertNil(Socks5.parseRequest(atyp: 0x01, payload: Data([127, 0, 0])))
    }

    func testDomain() {
        let host = "example.com"
        var payload = Data([UInt8(host.count)])
        payload.append(Data(host.utf8))
        payload.append(contentsOf: [0x00, 0x50]) // port 80
        let r = Socks5.parseRequest(atyp: 0x03, payload: payload)
        XCTAssertEqual(r, .init(host: "example.com", port: 80))
    }

    func testDomainRejectsMismatchedLength() {
        var payload = Data([9])
        payload.append(Data("ex.com".utf8))
        payload.append(contentsOf: [0x00, 0x50])
        XCTAssertNil(Socks5.parseRequest(atyp: 0x03, payload: payload))
    }

    func testDomainRejectsZeroLength() {
        XCTAssertNil(Socks5.parseRequest(atyp: 0x03, payload: Data([0, 0, 80])))
    }

    func testIPv6() {
        // ::1 : 443
        var payload = Data(repeating: 0, count: 16)
        payload[15] = 1
        payload.append(contentsOf: [0x01, 0xBB])
        let r = Socks5.parseRequest(atyp: 0x04, payload: payload)
        XCTAssertEqual(r, .init(host: "::1", port: 443))
    }

    func testIPv6FullAddress() {
        // 2001:db8::ff00:42 : 22
        var payload = Data([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0x00, 0, 0x42])
        payload.append(contentsOf: [0x00, 0x16])
        let r = Socks5.parseRequest(atyp: 0x04, payload: payload)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.port, 22)
        XCTAssertTrue(r?.host.contains("2001") == true)
    }

    func testPortParsingIsSliceSafe() {
        // A Data slice keeps its parent's indices — indexing it at 0 is
        // the exact crash this parser must never repeat.
        var bigger = Data([0xDE, 0xAD])
        bigger.append(contentsOf: [10, 0, 0, 9, 0x1F, 0x91])
        let slice = bigger.suffix(6)
        let r = Socks5.parseRequest(atyp: 0x01, payload: Data(slice))
        XCTAssertEqual(r, .init(host: "10.0.0.9", port: 8081))
    }

    func testRejectsUnknownATYP() {
        XCTAssertNil(Socks5.parseRequest(atyp: 0x02, payload: Data(repeating: 0, count: 6)))
    }
}
