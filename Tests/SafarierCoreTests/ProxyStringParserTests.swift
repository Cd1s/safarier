import XCTest
@testable import SafarierCore

final class ProxyStringParserTests: XCTestCase {
    func testParsesHostPortUserPassWithHalfAndFullWidthColons() throws {
        let half = try XCTUnwrap(ProxyStringParser.parse("192.168.1.10:8080:alice:s3cr3t"))
        XCTAssertNil(half.kind)
        XCTAssertEqual(half.host, "192.168.1.10")
        XCTAssertEqual(half.port, 8080)
        XCTAssertEqual(half.username, "alice")
        XCTAssertEqual(half.password, "s3cr3t")

        let full = try XCTUnwrap(ProxyStringParser.parse("proxy.example.com:1080：bob：pa:ss"))
        XCTAssertEqual(full.host, "proxy.example.com")
        XCTAssertEqual(full.port, 1080)
        XCTAssertEqual(full.username, "bob")
        XCTAssertEqual(full.password, "pa:ss")
    }

    func testParsesURLAndAtSeparatedFormats() throws {
        let socks = try XCTUnwrap(ProxyStringParser.parse("socks5://user%401:p%3Ass@127.0.0.1:1080/"))
        XCTAssertEqual(socks.kind, .socks5)
        XCTAssertEqual(socks.host, "127.0.0.1")
        XCTAssertEqual(socks.port, 1080)
        XCTAssertEqual(socks.username, "user@1")
        XCTAssertEqual(socks.password, "p:ss")

        let http = try XCTUnwrap(ProxyStringParser.parse("http://u1:p1@10.0.0.2:3128"))
        XCTAssertEqual(http.kind, .httpConnect)
        XCTAssertEqual(http.host, "10.0.0.2")
        XCTAssertEqual(http.port, 3128)
        XCTAssertEqual(http.username, "u1")
        XCTAssertEqual(http.password, "p1")

        let atOnly = try XCTUnwrap(ProxyStringParser.parse("u2:p2@example.org:8888"))
        XCTAssertNil(atOnly.kind)
        XCTAssertEqual(atOnly.host, "example.org")
        XCTAssertEqual(atOnly.port, 8888)
        XCTAssertEqual(atOnly.username, "u2")
        XCTAssertEqual(atOnly.password, "p2")
    }

    func testHandlesIPv6AndInvalidInputs() throws {
        let bracketed = try XCTUnwrap(ProxyStringParser.parse("[::1]:1080:user:pass"))
        XCTAssertEqual(bracketed.host, "::1")
        XCTAssertEqual(bracketed.port, 1080)
        XCTAssertEqual(bracketed.username, "user")
        XCTAssertEqual(bracketed.password, "pass")

        XCTAssertNil(ProxyStringParser.parse("2001:db8::1"))
        XCTAssertNil(ProxyStringParser.parse("example.com"))
        XCTAssertNil(ProxyStringParser.parse("1.2.3.4:70000:u:p"))
        XCTAssertNil(ProxyStringParser.parse(""))
    }

    func testAutoFillSkipsSingleCharHostPortTypingButTriggersOnPaste() {
        XCTAssertNil(ProxyStringParser.parseForAutoFill(oldValue: "1.2.3.4:80", newValue: "1.2.3.4:808"))
        XCTAssertNotNil(ProxyStringParser.parseForAutoFill(oldValue: "", newValue: "1.2.3.4:8080"))
        XCTAssertNotNil(ProxyStringParser.parseForAutoFill(oldValue: "1.2.3.4:8080:u:", newValue: "1.2.3.4:8080:u:p"))
    }
}
