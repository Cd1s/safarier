import Foundation
import XCTest
@testable import SafarierNetwork

final class ClashSubscriptionParserTests: XCTestCase {
    static let subscription = """
    # A full Clash document, not a list of node URIs.
    mixed-port: 7890
    allow-lan: true
    external-controller: 0.0.0.0:9090
    proxies:
      - name: Example
        type: hysteria2
        server: proxy.example.com
        ports: 20000-30000,443
        password: 'sample:credential'
        skip-cert-verify: true
        sni: tls.example.com
        alpn: [h3]
        obfs: salamander
        obfs-password: sample-obfs
    rules: [MATCH,DIRECT]
    """

    func testHoppingYAMLBuildsIsolatedHysteriaOutbound() throws {
        let result = try SubscriptionParser.parseResult(Self.subscription)
        let node = try XCTUnwrap(result.nodes.first)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertTrue(result.skippedSchemes.isEmpty)
        XCTAssertEqual(node.type.rawValue, "hysteria2")
        XCTAssertEqual(node.password, "sample:credential")
        XCTAssertEqual(node.serverPort, 20000)
        let config = try SingboxConfigBuilder.makeConfiguration(inboundPort: 12345, node: node)
        let outbound = try XCTUnwrap(config.outbounds.first)
        XCTAssertEqual(outbound["server_ports"], .array([.string("20000:30000"), .string("443:443")]))
        XCTAssertNil(outbound["server_port"])
        XCTAssertEqual(outbound["tls"], .object([
            "enabled": .bool(true), "insecure": .bool(true),
            "server_name": .string("tls.example.com"), "alpn": .array([.string("h3")])
        ]))
        XCTAssertEqual(outbound["obfs"], .object(["type": .string("salamander"), "password": .string("sample-obfs")]))
        XCTAssertEqual(config.inbounds.first?["listen"], .string("127.0.0.1"))
        XCTAssertEqual(config.inbounds.first?["listen_port"], .number(12345))
        XCTAssertEqual(config.route, ["final": .string("proxy")])
    }

    func testFlowStyleAndSinglePortKeepTLSVerificationEnabled() throws {
        let text = """
        proxies:
        - {name: 'Flow #1', type: hysteria2, server: '2001:db8::1', port: 443, password: '001234'}
        - {name: unsupported, type: tuic}
        """
        let result = try SubscriptionParser.parseResult("\u{FEFF}" + text)
        XCTAssertEqual(result.skippedSchemes, ["tuic": 1])
        let node = try XCTUnwrap(result.nodes.first)
        XCTAssertEqual(node.password, "001234")
        let outbound = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 12345, node: node).outbounds.first)
        XCTAssertEqual(outbound["server_port"], .number(443))
        XCTAssertNil(outbound["server_ports"])
        XCTAssertEqual(outbound["tls"], .object(["enabled": .bool(true)]))
    }

    func testInvalidRangesAndCredentialsFailWithoutLeakingContent() {
        for ports in ["", "0", "65536", "300-200", "1-2-3", "443,", "abc"] {
            assertInvalid(Self.subscription.replacingOccurrences(of: "20000-30000,443", with: "'\(ports)'"))
        }
        assertInvalid(Self.subscription.replacingOccurrences(of: "sample:credential", with: ""))
        assertInvalid("proxies: [broken")
        assertInvalid("proxies: {}")
    }

    func testUnsupportedOnlyAndEmptyList() throws {
        XCTAssertThrowsError(try SubscriptionParser.parseResult("proxies: [{type: tuic}]")) {
            XCTAssertEqual($0 as? SubscriptionParseError, .unsupportedScheme("tuic"))
        }
        XCTAssertTrue(try SubscriptionParser.parseResult("proxies: []").nodes.isEmpty)
    }

    func testLocalFileUsesSameImportPath() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.subscription.write(to: url, atomically: true, encoding: .utf8)
        let result = try await SubscriptionFetcher().fetchResult(from: url)
        XCTAssertEqual(result.nodes.first?.type.rawValue, "hysteria2")
    }

    private func assertInvalid(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SubscriptionParser.parseResult(text), file: file, line: line) {
            XCTAssertEqual($0 as? SubscriptionParseError, .invalidClash, file: file, line: line)
        }
    }
}
