import XCTest
import SafarierCore
@testable import SafarierNetwork

final class SingboxConfigBuilderTests: XCTestCase {
    func testConfigurationContainsSocksInboundAndProxyOutbound() throws {
        let node = SubscriptionNode(
            name: "Tokyo",
            type: .vless,
            server: "edge.example.com",
            serverPort: 443,
            uuid: "00000000-0000-0000-0000-000000000001",
            tls: true,
            serverName: "edge.example.com",
            transport: "ws",
            transportPath: "/proxy"
        )

        let data = try SingboxConfigBuilder.build(inboundPort: 20_001, node: node)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inbounds = try XCTUnwrap(object["inbounds"] as? [[String: Any]])
        let outbounds = try XCTUnwrap(object["outbounds"] as? [[String: Any]])

        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds[0]["type"] as? String, "socks")
        XCTAssertEqual(inbounds[0]["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(inbounds[0]["listen_port"] as? Int, 20_001)
        XCTAssertEqual(outbounds.first?["type"] as? String, "vless")
        XCTAssertEqual(outbounds.first?["server"] as? String, "edge.example.com")
        XCTAssertEqual(outbounds.last?["tag"] as? String, "direct")
        XCTAssertEqual((object["route"] as? [String: Any])?["final"] as? String, "proxy")
    }

    func testAllSupportedProtocolsMapToSingboxTypes() throws {
        let nodes = [
            SubscriptionNode(name: "v", type: .vless, server: "v.example", serverPort: 443, uuid: UUID().uuidString),
            SubscriptionNode(name: "m", type: .vmess, server: "m.example", serverPort: 443, uuid: UUID().uuidString),
            SubscriptionNode(name: "t", type: .trojan, server: "t.example", serverPort: 443, password: "secret"),
            SubscriptionNode(name: "s", type: .shadowsocks, server: "s.example", serverPort: 8388, password: "secret", method: "aes-128-gcm"),
            SubscriptionNode(name: "k", type: .socks, server: "k.example", serverPort: 1080),
            SubscriptionNode(name: "a", type: .anytls, server: "a.example", serverPort: 443, password: "secret"),
        ]
        let expected = ["vless", "vmess", "trojan", "shadowsocks", "socks", "anytls"]
        for (node, type) in zip(nodes, expected) {
            let config = try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node)
            XCTAssertEqual(config.outbounds.first?["type"], .string(type))
        }
    }

    func testParserHandlesBase64SubscriptionAndVLESSQuery() throws {
        let line = "vless://00000000-0000-0000-0000-000000000001@edge.example.com:443?security=tls&sni=edge.example.com&type=ws&path=%2Fproxy#Tokyo"
        let encoded = Data(line.utf8).base64EncodedString()
        let node = try XCTUnwrap(SubscriptionParser.parse(encoded).first)
        XCTAssertEqual(node.name, "Tokyo")
        XCTAssertEqual(node.type, .vless)
        XCTAssertTrue(node.tls)
        XCTAssertEqual(node.transportPath, "/proxy")
    }

    func testInvalidInboundPortThrows() {
        let node = SubscriptionNode(name: "n", type: .trojan, server: "example.com", serverPort: 443, password: "p")
        XCTAssertThrowsError(try SingboxConfigBuilder.build(inboundPort: 0, node: node)) { error in
            XCTAssertEqual(error as? SingboxConfigError, .invalidInboundPort(0))
        }
    }

    func testInboundUsesOnlyFieldsSingbox114Accepts() throws {
        let node = SubscriptionNode(name: "k", type: .socks, server: "192.0.2.6", serverPort: 20001)
        let config = try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node, logLevel: "warn")
        XCTAssertEqual(Set(try XCTUnwrap(config.inbounds.first).keys), ["type", "tag", "listen", "listen_port"])
        XCTAssertEqual(config.log["level"], .string("warn"))
        XCTAssertEqual(config.route, ["final": .string("proxy")])
    }

    func testSOCKSOutboundWithAndWithoutCredentials() throws {
        let anonymous = SubscriptionNode(name: "k", type: .socks, server: "192.0.2.6", serverPort: 20001)
        let open = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: anonymous).outbounds.first)
        XCTAssertEqual(open, [
            "type": .string("socks"), "tag": .string("proxy"),
            "server": .string("192.0.2.6"), "server_port": .number(20001), "version": .string("5"),
        ])

        let authed = SubscriptionNode(name: "k", type: .socks, server: "p.example", serverPort: 1080, username: "alice", password: "pw")
        let outbound = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: authed).outbounds.first)
        XCTAssertEqual(outbound["username"], .string("alice"))
        XCTAssertEqual(outbound["password"], .string("pw"))
        XCTAssertNil(outbound["tls"])
    }

    func testAnyTLSOutboundAlwaysHasTLS() throws {
        let node = SubscriptionNode(
            name: "a", type: .anytls, server: "edge.example.com", serverPort: 8443, password: "pw",
            tls: false, serverName: "cdn.example.com", parameters: ["insecure": "1"]
        )
        let outbound = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node).outbounds.first)
        XCTAssertEqual(outbound["type"], .string("anytls"))
        XCTAssertEqual(outbound["password"], .string("pw"))
        XCTAssertEqual(outbound["tls"], .object(["enabled": .bool(true), "server_name": .string("cdn.example.com"), "insecure": .bool(true)]))
    }

    func testSOCKSWithPasswordButNoUsernameIsInvalid() {
        let node = SubscriptionNode(name: "k", type: .socks, server: "p.example", serverPort: 1080, password: "pw")
        XCTAssertThrowsError(try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node))
    }

    static let realityKey = "ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1-f4CBgoM"

    func testVLESSRealityMapsToSingboxRealityAndUTLS() throws {
        let node = try SubscriptionParser.parseLine(
            "vless://00000000-0000-0000-0000-000000000001@r.example:443?security=reality&sni=www.apple.com&fp=Safari&pbk=\(Self.realityKey)&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision&type=tcp#reality"
        )
        let outbound = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node).outbounds.first)
        XCTAssertEqual(outbound["flow"], .string("xtls-rprx-vision"))
        XCTAssertEqual(outbound["tls"], .object([
            "enabled": .bool(true),
            "server_name": .string("www.apple.com"),
            "reality": .object(["enabled": .bool(true), "public_key": .string(Self.realityKey), "short_id": .string("6ba85179e30d4fc2")]),
            "utls": .object(["enabled": .bool(true), "fingerprint": .string("safari")]),
        ]))
    }

    func testRealityWithoutFingerprintDefaultsToChromeUTLS() throws {
        let node = SubscriptionNode(
            name: "r", type: .vless, server: "r.example", serverPort: 443, uuid: UUID().uuidString,
            serverName: "www.apple.com", parameters: ["pbk": Self.realityKey]
        )
        let tls = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node).outbounds.first?["tls"])
        guard case .object(let object) = tls else { return XCTFail("\(tls)") }
        XCTAssertEqual(object["reality"], .object(["enabled": .bool(true), "public_key": .string(Self.realityKey)]))
        XCTAssertEqual(object["utls"], .object(["enabled": .bool(true), "fingerprint": .string("chrome")]), "sing-box 的 Reality 必须开 uTLS")
    }

    func testPlainTLSOnlyAddsUTLSWhenFingerprintGiven() throws {
        let plain = SubscriptionNode(name: "t", type: .trojan, server: "t.example", serverPort: 443, password: "p", tls: true)
        XCTAssertEqual(try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: plain).outbounds.first?["tls"], .object(["enabled": .bool(true)]))
        var fingerprinted = plain
        fingerprinted.parameters = ["fp": "firefox", "pbk": Self.realityKey]
        XCTAssertEqual(
            try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: fingerprinted).outbounds.first?["tls"],
            .object(["enabled": .bool(true), "utls": .object(["enabled": .bool(true), "fingerprint": .string("firefox")])]),
            "Reality 只用于 VLESS"
        )
    }

    func testShadowsocks2022OutboundKeepsKeyAndPlugin() throws {
        let key = "++++////AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo="
        let node = try SubscriptionParser.parseLine(
            "ss://2022-blake3-aes-256-gcm:\(key)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com&uot=1#ss"
        )
        let outbound = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node).outbounds.first)
        XCTAssertEqual(outbound["type"], .string("shadowsocks"))
        XCTAssertEqual(outbound["method"], .string("2022-blake3-aes-256-gcm"))
        XCTAssertEqual(outbound["password"], .string(key))
        XCTAssertEqual(outbound["plugin"], .string("obfs-local"))
        XCTAssertEqual(outbound["plugin_opts"], .string("obfs=http;obfs-host=cdn.example.com"))
        XCTAssertEqual(outbound["udp_over_tcp"], .bool(true))
        XCTAssertNil(outbound["tls"])
    }

    func testTransportMapping() {
        func transport(_ type: String?, path: String? = nil, host: String? = nil, parameters: [String: String] = [:]) -> [String: SingboxJSONValue]? {
            SingboxConfigBuilder.makeTransport(SubscriptionNode(
                name: "n", type: .vless, server: "v.example", serverPort: 443, uuid: UUID().uuidString,
                transport: type, transportPath: path, transportHost: host, parameters: parameters
            ))
        }
        XCTAssertNil(transport("tcp", host: "h.example"), "sing-box 没有 tcp 传输层")
        XCTAssertNil(transport("raw"))
        XCTAssertNil(transport(nil))
        XCTAssertEqual(transport("ws", path: "/ws?ed=2048", host: "cdn.example.com"), [
            "type": .string("ws"), "path": .string("/ws"), "headers": .object(["Host": .string("cdn.example.com")]),
            "max_early_data": .number(2048), "early_data_header_name": .string("Sec-WebSocket-Protocol"),
        ])
        XCTAssertEqual(transport("h2", path: "/h2", host: "a.example, b.example"), [
            "type": .string("http"), "path": .string("/h2"), "host": .array([.string("a.example"), .string("b.example")]),
        ])
        XCTAssertEqual(transport("grpc", parameters: ["serviceName": "svc"]), ["type": .string("grpc"), "service_name": .string("svc")])
        XCTAssertEqual(transport("httpupgrade", path: "/up", host: "h.example"), [
            "type": .string("httpupgrade"), "path": .string("/up"), "host": .string("h.example"),
        ])
    }

    /// 以前保存的节点里可能还是 URL-safe / 没补齐的 SS2022 密钥：生成配置时再规范化一次。
    func testStoredSS2022KeyIsNormalizedWhenBuildingConfig() throws {
        let node = SubscriptionNode(
            name: "old", type: .shadowsocks, server: "ss.example.com", serverPort: 8388,
            password: "----____AQIDBAUGBwgJCg:ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1-f4CBgoM", method: "2022-blake3-aes-128-gcm"
        )
        let outbound = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node).outbounds.first)
        XCTAssertEqual(outbound["password"], .string("++++////AQIDBAUGBwgJCg==:ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CBgoM="))
        var classic = node
        classic.method = "aes-128-gcm"
        classic.password = "a-b_c"
        XCTAssertEqual(try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: classic).outbounds.first?["password"], .string("a-b_c"))
    }

    /// 以前保存的节点方法名可能是大写或手滑写错（`aes-128-grm`）：生成配置时自愈，未知加密方式则拒绝。
    func testStoredShadowsocksMethodIsHealedWhenBuildingConfig() throws {
        for (stored, expected) in [("aes-128-grm", "aes-128-gcm"), ("AES-128-GCM", "aes-128-gcm"), ("chacha20-poly1305", "chacha20-ietf-poly1305")] {
            let node = SubscriptionNode(name: "old", type: .shadowsocks, server: "ss.example.com", serverPort: 8388, password: "secret", method: stored)
            let outbound = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node).outbounds.first)
            XCTAssertEqual(outbound["method"], .string(expected), stored)
        }
        let bad = SubscriptionNode(name: "bad", type: .shadowsocks, server: "ss.example.com", serverPort: 8388, password: "secret", method: "aes-128-xyz")
        XCTAssertThrowsError(try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: bad))
    }

    /// `plugin=%3B`（只有分号）以前会数组越界崩溃：插件名为空就不写插件。
    func testShadowsocksPluginWithEmptyNameIsIgnored() throws {
        func outbound(_ plugin: String) throws -> [String: SingboxJSONValue] {
            let node = SubscriptionNode(name: "s", type: .shadowsocks, server: "s.example", serverPort: 8388,
                                        password: "pw", method: "aes-128-gcm", parameters: ["plugin": plugin])
            return try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node).outbounds.first)
        }
        for plugin in [";", "  ;obfs=http", ";;"] {
            let result = try outbound(plugin)
            XCTAssertNil(result["plugin"], plugin)
            XCTAssertNil(result["plugin_opts"], plugin)
        }
        let bare = try outbound("obfs-local;")
        XCTAssertEqual(bare["plugin"], .string("obfs-local"))
        XCTAssertNil(bare["plugin_opts"])
        XCTAssertEqual(try outbound("simple-obfs;obfs=tls")["plugin"], .string("obfs-local"))
        XCTAssertEqual(try SubscriptionParser.parseLine("ss://aes-128-gcm:pw@s.example:8388/?plugin=%3B#s").parameters["plugin"], ";")
    }

    func testTLSALPN() throws {
        let node = try SubscriptionParser.parseLine("trojan://pw@t.example:443?sni=t.example&alpn=h2%2C%20http%2F1.1%2C#t")
        let tls = try XCTUnwrap(SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node).outbounds.first?["tls"])
        guard case .object(let object) = tls else { return XCTFail("\(tls)") }
        XCTAssertEqual(object["alpn"], .array([.string("h2"), .string("http/1.1")]))
        let empty = try SubscriptionParser.parseLine("trojan://pw@t.example:443?alpn=#t")
        guard case .object(let plain)? = try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: empty).outbounds.first?["tls"] else { return XCTFail() }
        XCTAssertNil(plain["alpn"])
    }

    /// `?ed=` 只拿走合法的那一个参数，路径里其它查询参数保留；不合法的 ed 原样留在路径里。
    func testWebSocketEarlyDataParsing() {
        func ws(_ path: String) -> [String: SingboxJSONValue]? {
            SingboxConfigBuilder.makeTransport(SubscriptionNode(name: "n", type: .vless, server: "v.example", serverPort: 443,
                                                                uuid: UUID().uuidString, transport: "ws", transportPath: path))
        }
        XCTAssertEqual(ws("/ws?ed=2048&foo=1")?["path"], .string("/ws?foo=1"))
        XCTAssertEqual(ws("/ws?ed=2048&foo=1")?["max_early_data"], .number(2048))
        XCTAssertEqual(ws("/ws?foo=1&ed=512")?["path"], .string("/ws?foo=1"))
        XCTAssertEqual(ws("/ws?foo=1&ed=512")?["max_early_data"], .number(512))
        for invalid in ["/ws?ed=0", "/ws?ed=-1", "/ws?ed=99999999999", "/ws?ed=abc", "/ws?speed=2048"] {
            XCTAssertEqual(ws(invalid)?["path"], .string(invalid), invalid)
            XCTAssertNil(ws(invalid)?["max_early_data"], invalid)
        }
        XCTAssertEqual(ws("/ws?ed=4294967295")?["max_early_data"], .number(4_294_967_295), "UInt32 最大值")
    }

    /// 要校验的 sing-box：本机找到的（Homebrew 等），以及仓库里打包用的 `.build/sing-box/sing-box`（有的话）。
    private static var singboxExecutables: [URL] {
        let bundled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sing-box/sing-box")
        let candidates = [SingboxProcessManager.locateExecutable(), FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil]
        var seen = Set<String>()
        return candidates.compactMap { $0 }.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// 用本机真实的 sing-box 校验每种协议生成的配置（没装 sing-box 时跳过）。
    func testGeneratedConfigsPassSingboxCheck() throws {
        let executables = Self.singboxExecutables
        guard !executables.isEmpty else { throw XCTSkip("本机没有 sing-box") }
        let nodes = [
            SubscriptionNode(name: "v", type: .vless, server: "v.example", serverPort: 443, uuid: UUID().uuidString, tls: true, serverName: "v.example", transport: "ws", transportPath: "/ws"),
            try SubscriptionParser.parseLine("vless://00000000-0000-0000-0000-000000000001@v.example:443?security=tls&sni=v.example&type=ws&host=cdn.example.com&path=%2Fws%3Fed%3D2048#ws-host"),
            try SubscriptionParser.parseLine("vless://00000000-0000-0000-0000-000000000001@v.example:443?security=tls&type=grpc&serviceName=svc#grpc"),
            try SubscriptionParser.parseLine("trojan://secret@t.example:443?sni=t.example&type=h2&host=t.example&path=%2Fh2#h2"),
            try SubscriptionParser.parseLine("vless://00000000-0000-0000-0000-000000000001@v.example:443?security=tls&type=httpupgrade&host=cdn.example.com&path=%2Fup#hu"),
            try SubscriptionParser.parseLine("trojan://pw@t.example:443?sni=t.example&alpn=h2%2Chttp%2F1.1#alpn"),
            try SubscriptionParser.parseLine("vless://00000000-0000-0000-0000-000000000001@v.example:443?security=tls&type=ws&path=%2Fws%3Fed%3D2048%26foo%3D1#ws-ed-query"),
            SubscriptionNode(name: "m", type: .vmess, server: "m.example", serverPort: 443, uuid: UUID().uuidString, method: "auto", tls: true, alterID: 0),
            SubscriptionNode(name: "t", type: .trojan, server: "t.example", serverPort: 443, password: "secret", tls: true, serverName: "t.example"),
            SubscriptionNode(name: "s", type: .shadowsocks, server: "s.example", serverPort: 8388, password: "secret", method: "aes-128-gcm"),
            try SubscriptionParser.parseLine("socks://Og%3D%3D@192.0.2.6:20001#lan-20001 edge-v6 20001"),
            try SubscriptionParser.parseLine("socks5://alice:pw@[2001:db8::1]:1080#v6"),
            try SubscriptionParser.parseLine("socks://\(Data("user:pass@example.com:1080".utf8).base64EncodedString())?obfs=none&remarks=US-Node"),
            try SubscriptionParser.parseLine("socks://\(Data("example.com:1080".utf8).base64EncodedString())?obfs=none"),
            try SubscriptionParser.parseLine("socks://\(Data("user:???>x".utf8).base64EncodedString())@example.com:1080"),
            try SubscriptionParser.parseLine("socks5h://user:p%40ss%3Aword@192.0.2.10:1080"),
            try SubscriptionParser.parseLine("anytls://pw@a.example:443?sni=a.example&insecure=1#a"),
            // SS2022：sing-box 会校验密钥长度（16 / 32 字节）。
            try SubscriptionParser.parseLine("ss://2022-blake3-aes-128-gcm:++++////AQIDBAUGBwgJCg==@ss.example.com:8388#ss2022-128"),
            try SubscriptionParser.parseLine("ss://2022-blake3-aes-256-gcm:++++////AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo=@ss.example.com:8388#ss2022-256"),
            try SubscriptionParser.parseLine("ss://2022-blake3-chacha20-poly1305:++++////AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo=@ss.example.com:8388#ss2022-chacha"),
            try SubscriptionParser.parseLine("ss://2022-blake3-aes-256-gcm:++++////AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo=:ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CBgoM=@[2001:db8::1]:8388#eih"),
            try SubscriptionParser.parseLine("ss://aes-128-gcm:secret@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com#obfs"),
            // URL-safe、省略 = 的 SS2022 密钥（不规范化时 sing-box 报 decode key: illegal base64 data）。
            try SubscriptionParser.parseLine("ss2022://2022-blake3-aes-128-gcm:----____AQIDBAUGBwgJCg@ss.example.com:8388#urlsafe-128"),
            try SubscriptionParser.parseLine("ss://2022-blake3-aes-256-gcm:----____AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo:ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1-f4CBgoM@[2001:db8::1]:8388#urlsafe-eih"),
            SubscriptionNode(name: "stored-urlsafe", type: .shadowsocks, server: "ss.example.com", serverPort: 8388,
                             password: "----____AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo", method: "2022-blake3-chacha20-poly1305"),
            try SubscriptionParser.parseLine("vless://00000000-0000-0000-0000-000000000001@r.example:443?security=reality&sni=www.apple.com&fp=chrome&pbk=\(Self.realityKey)&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision&type=tcp#reality"),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("singbox-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for executable in executables {
            for node in nodes {
                let url = directory.appendingPathComponent("\(node.type.rawValue)-\(node.id.uuidString).json")
                try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node, logLevel: "warn").encoded().write(to: url)
                let process = Process()
                process.executableURL = executable
                process.arguments = ["check", "-c", url.path]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                process.waitUntilExit()
                let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                XCTAssertEqual(process.terminationStatus, 0, "\(executable.path) \(node.name): \(message)")
            }
        }
    }
}
