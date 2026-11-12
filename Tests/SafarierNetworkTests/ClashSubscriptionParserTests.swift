import Foundation
import XCTest
import SafarierCore
@testable import SafarierNetwork

final class ClashSubscriptionParserTests: XCTestCase {
    func testLargeMixedFeedImportsHTTPSShadowsocksAndSOCKSWithoutDroppingNodes() throws {
        let counts: [(String, Int, String)] = [
            ("http", 200, "username: sample-user, password: sample-password, tls: true, sni: tls.example.com, skip-cert-verify: true"),
            ("vless", 11, "uuid: 00000000-0000-0000-0000-000000000001"),
            ("anytls", 2, "password: sample-password"),
            ("trojan", 5, "password: sample-password"),
            ("ss", 2, "cipher: aes-256-gcm, password: sample-password"),
            ("socks5", 6, "username: sample-user, password: sample-password")
        ]
        let entries = counts.flatMap { type, count, fields in
            (0..<count).map { "  - {name: '\(type) \($0)', type: \(type), server: proxy.example.com, port: 443, \(fields)}" }
        }
        let result = try SubscriptionParser.parseResult("proxies:\n" + entries.joined(separator: "\n"))
        XCTAssertEqual(result.nodes.count, 226)
        XCTAssertTrue(result.skippedSchemes.isEmpty)
        XCTAssertEqual(result.nodes.filter { $0.type == .http }.count, 200)
        XCTAssertEqual(result.nodes.filter { $0.type == .socks }.count, 6)
        XCTAssertEqual(result.nodes.filter { $0.type == .shadowsocks }.count, 2)
        XCTAssertEqual(try JSONDecoder().decode([SubscriptionNode].self, from: JSONEncoder().encode(result.nodes)), result.nodes)
        let https = SingboxConfigBuilder.makeOutbound(try XCTUnwrap(result.nodes.first))
        XCTAssertEqual(https["type"], .string("http"))
        XCTAssertEqual(https["username"], .string("sample-user"))
        XCTAssertEqual(https["password"], .string("sample-password"))
        XCTAssertEqual(https["tls"], .object(["enabled": .bool(true), "server_name": .string("tls.example.com"), "insecure": .bool(true)]))
        let ss = SingboxConfigBuilder.makeOutbound(try XCTUnwrap(result.nodes.first { $0.type == .shadowsocks }))
        XCTAssertEqual(ss["method"], .string("aes-256-gcm"))
        let socks = SingboxConfigBuilder.makeOutbound(try XCTUnwrap(result.nodes.last))
        XCTAssertEqual(socks["version"], .string("5"))
        XCTAssertEqual(socks["username"], .string("sample-user"))
    }

    func testHTTPAliasesOptionalAuthenticationAndVMessTransport() throws {
        let result = try SubscriptionParser.parseResult("""
        proxies:
          - {name: HTTP, type: http, server: proxy.example.com, port: 8080}
          - {name: HTTPS, type: https, server: proxy.example.com, port: 443}
          - {name: SOCKS, type: socks5, server: proxy.example.com, port: 1080}
          - {name: VMess, type: vmess, server: proxy.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, alterId: 0, cipher: auto, network: ws, ws-opts: {path: /vmess}, tls: true}
        """)
        XCTAssertEqual(result.nodes.map(\.type), [.http, .http, .socks, .vmess])
        XCTAssertFalse(result.nodes[0].tls)
        XCTAssertTrue(result.nodes[1].tls)
        let outbound = SingboxConfigBuilder.makeOutbound(result.nodes[3])
        XCTAssertEqual(outbound["alter_id"], .number(0))
        XCTAssertEqual(outbound["security"], .string("auto"))
        XCTAssertEqual(outbound["transport"], .object(["type": .string("ws"), "path": .string("/vmess")]))
        assertInvalid("proxies: [{name: Bad, type: ss, server: proxy.example.com, port: 443, password: sample}]")
        assertInvalid("proxies: [{name: Bad, type: http, server: proxy.example.com, port: 443, password: sample}]")
    }

    func testShadowsocksClashPluginOptionsArePreserved() throws {
        let nodes = try SubscriptionParser.parse("""
        proxies:
          - {name: Obfs, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: sample, plugin: obfs, plugin-opts: {mode: http, host: cdn.example.com}}
          - {name: WS, type: ss, server: proxy.example.com, port: 443, cipher: aes-256-gcm, password: sample, plugin: v2ray-plugin, plugin-opts: {mode: websocket, host: cdn.example.com, path: /ws, tls: true, mux: false}}
        """)
        let obfs = SingboxConfigBuilder.makeOutbound(nodes[0])
        XCTAssertEqual(obfs["plugin"], .string("obfs-local"))
        XCTAssertEqual(obfs["plugin_opts"], .string("obfs=http;obfs-host=cdn.example.com"))
        XCTAssertEqual(nodes[1].parameters["plugin"], "v2ray-plugin;mode=websocket;host=cdn.example.com;path=/ws;tls")
    }

    static let mixedProtocols = """
    proxies:
      - {name: Trojan, type: trojan, server: trojan.example.com, port: 443, password: 'sample:password', sni: tls.example.com, skip-cert-verify: true, ip-version: ipv6-prefer, udp: true}
      - {name: AnyTLS, type: anytls, server: anytls.example.com, port: 443, password: 'sample:password', sni: tls.example.com, skip-cert-verify: false}
      - {name: Mieru, type: mieru, server: mieru.example.com, port: 8080, username: sample-user, password: 'sample:password', transport: TCP, multiplexing: MULTIPLEXING_LOW}
      - name: Reality
        type: vless
        server: reality.example.com
        port: 443
        uuid: 00000000-0000-0000-0000-000000000001
        tls: true
        network: tcp
        servername: tls.example.com
        flow: xtls-rprx-vision
        client-fingerprint: chrome
        reality-opts: {public-key: AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8, short-id: '0123456789abcdef'}
    dns: {enable: true, nameserver: ['https://dns.invalid/dns-query']}
    rules: [MATCH,DIRECT]
    """

    func testImportsAllRequestedClashProtocolsAndPreservesTLSAndReality() throws {
        let result = try SubscriptionParser.parseResult(Self.mixedProtocols)
        XCTAssertEqual(result.nodes.map(\.type), [.trojan, .anytls, .mieru, .vless])
        XCTAssertTrue(result.skippedSchemes.isEmpty)
        let trojan = try SingboxConfigBuilder.makeConfiguration(inboundPort: 12345, node: result.nodes[0])
        XCTAssertEqual(trojan.outbounds[0]["tls"], .object([
            "enabled": .bool(true), "server_name": .string("tls.example.com"), "insecure": .bool(true)
        ]))
        XCTAssertEqual(trojan.outbounds[0]["domain_resolver"], .object([
            "server": .string("node-dns"), "strategy": .string("prefer_ipv6")
        ]))
        XCTAssertEqual(trojan.dns?["servers"], .array([.object(["type": .string("local"), "tag": .string("node-dns")])]))
        let anytls = SingboxConfigBuilder.makeOutbound(result.nodes[1])
        XCTAssertEqual(anytls["tls"], .object(["enabled": .bool(true), "server_name": .string("tls.example.com")]))
        XCTAssertEqual(result.nodes[2].username, "sample-user")
        XCTAssertEqual(result.nodes[2].parameters["multiplexing"], "MULTIPLEXING_LOW")
        let reality = SingboxConfigBuilder.makeOutbound(result.nodes[3])
        XCTAssertEqual(reality["flow"], .string("xtls-rprx-vision"))
        XCTAssertNil(reality["transport"])
        guard case .object(let tls) = reality["tls"] else { return XCTFail("TLS missing") }
        XCTAssertEqual(tls["utls"], .object(["enabled": .bool(true), "fingerprint": .string("chrome")]))
        XCTAssertEqual(tls["reality"], .object(["enabled": .bool(true),
            "public_key": .string("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"), "short_id": .string("0123456789abcdef")]))
        XCTAssertEqual(trojan.route, ["final": .string("proxy")])
    }

    func testMixedClashRoundTripAndBase64Import() throws {
        let nodes = try SubscriptionParser.parse(Self.mixedProtocols)
        XCTAssertEqual(try JSONDecoder().decode([SubscriptionNode].self, from: JSONEncoder().encode(nodes)), nodes)
        XCTAssertEqual(try SubscriptionParser.parse(Data(Self.mixedProtocols.utf8).base64EncodedString()).map(\.type), nodes.map(\.type))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try InlineSubscription.store(Self.mixedProtocols, id: UUID(), in: root)
        XCTAssertEqual(stored.result.nodes.count, 4)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: stored.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidSupportedProtocolsFailWithoutExposingCredentials() {
        for change in [
            ("username: sample-user", "username: ''"), ("transport: TCP", "transport: invalid"),
            ("MULTIPLEXING_LOW", "MULTIPLEXING_BOGUS"), ("tls: true", "tls: false"),
            ("network: tcp", "network: xhttp"), ("ipv6-prefer", "ipv7"),
            ("public-key: AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "public-key: ''"),
            ("password: 'sample:password'", "password: ''")
        ] { assertInvalid(Self.mixedProtocols.replacingOccurrences(of: change.0, with: change.1)) }
    }

    func testUnsupportedEntriesDoNotDecodeKnownFields() throws {
        let result = try SubscriptionParser.parseResult(Self.mixedProtocols.replacingOccurrences(of: "proxies:", with: "proxies:\n  - {type: tuic, password: {future: shape}, port: auto}"))
        XCTAssertEqual(result.nodes.count, 4)
        XCTAssertEqual(result.skippedSchemes, ["tuic": 1])
    }

    func testClashWebSocketAndGRPCOptions() throws {
        let text = """
        proxies:
          - {type: trojan, name: WS, server: proxy.example.com, port: 443, password: sample, network: ws, ws-opts: {path: /ws, headers: {Host: cdn.example.com}}}
          - {type: vless, name: gRPC, server: proxy.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, network: grpc, grpc-opts: {grpc-service-name: example}}
        """
        let nodes = try SubscriptionParser.parse(text)
        XCTAssertEqual(SingboxConfigBuilder.makeTransport(nodes[0]), ["type": .string("ws"), "path": .string("/ws"),
            "headers": .object(["Host": .string("cdn.example.com")])])
        XCTAssertEqual(SingboxConfigBuilder.makeTransport(nodes[1]), ["type": .string("grpc"), "service_name": .string("example")])
    }

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
