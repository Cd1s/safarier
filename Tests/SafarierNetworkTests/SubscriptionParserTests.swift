import XCTest
import SafarierCore
@testable import SafarierNetwork

final class SubscriptionParserTests: XCTestCase {
    /// 真实订阅里常见的格式：userinfo 是 base64(":")（无认证），节点名带空格。
    func testSOCKSLineWithSpacesInNameAndEmptyBase64Credentials() throws {
        let node = try SubscriptionParser.parseLine("socks://Og%3D%3D@192.0.2.6:20001#lan-20001 edge-v6 20001")
        XCTAssertEqual(node.type, .socks)
        XCTAssertEqual(node.name, "lan-20001 edge-v6 20001")
        XCTAssertEqual(node.server, "192.0.2.6")
        XCTAssertEqual(node.serverPort, 20001)
        XCTAssertNil(node.username)
        XCTAssertNil(node.password)
        XCTAssertNoThrow(try node.validate())
    }

    func testSOCKSBase64AndPlainCredentials() throws {
        let encoded = Data("alice:s3cret".utf8).base64EncodedString()
        let base64 = try SubscriptionParser.parseLine("socks://\(encoded)@proxy.example:1080#b64")
        XCTAssertEqual(base64.username, "alice")
        XCTAssertEqual(base64.password, "s3cret")

        let plain = try SubscriptionParser.parseLine("socks5://bob:p%40ss%3Aword@proxy.example:1081#plain")
        XCTAssertEqual(plain.type, .socks)
        XCTAssertEqual(plain.username, "bob")
        XCTAssertEqual(plain.password, "p@ss:word")
        XCTAssertEqual(plain.serverPort, 1081)

        let anonymous = try SubscriptionParser.parseLine("socks5://10.0.0.1:1080")
        XCTAssertNil(anonymous.username)
        XCTAssertEqual(anonymous.name, "10.0.0.1")
    }

    func testSOCKSWholeBase64Authority() throws {
        for prefix in SubscriptionParser.socksPrefixes {
            let token = Data("user:pass@192.0.2.10:1080".utf8).base64EncodedString()
            let node = try SubscriptionParser.parseLine("\(prefix)\(token)?obfs=none#Example%20Node")
            XCTAssertEqual(node.type, .socks)
            XCTAssertEqual(node.server, "192.0.2.10")
            XCTAssertEqual(node.serverPort, 1080)
            XCTAssertEqual(node.username, "user")
            XCTAssertEqual(node.password, "pass")
            XCTAssertEqual(node.name, "Example Node")
            XCTAssertEqual(node.parameters["obfs"], "none")
            XCTAssertNoThrow(try node.validate())
        }
        let anonymousToken = Data("example.com:1081".utf8).base64EncodedString()
        let anonymous = try SubscriptionParser.parseLine("socks://\(anonymousToken)?obfs=none")
        XCTAssertEqual(anonymous.name, "example.com")
        XCTAssertEqual(anonymous.serverPort, 1081)
        XCTAssertNil(anonymous.username)
        XCTAssertNil(anonymous.password)

        let ipv6Token = Data("user:p@ss:word@[2001:db8::1]:1082".utf8).base64EncodedString()
        let ipv6 = try SubscriptionParser.parseLine("socks://\(ipv6Token)")
        XCTAssertEqual(ipv6.server, "2001:db8::1")
        XCTAssertEqual(ipv6.password, "p@ss:word")
    }

    func testSOCKSNameFallsBackToQueryThenHost() throws {
        let token = Data("user:pass@example.com:1080".utf8).base64EncodedString()
        for (suffix, expected) in [
            ("?obfs=none&remarks=US-Node", "US-Node"),
            ("?remark=Example%20Node", "Example Node"),
            ("?remarks=&remark=Fallback", "Fallback"),
            ("?remarks=First&remark=Second", "First"),
            ("?remarks=Query#Fragment", "Fragment"),
            ("?remarks=", "example.com"),
        ] {
            XCTAssertEqual(try SubscriptionParser.parseLine("socks://\(token)\(suffix)").name, expected)
        }
    }

    func testSOCKSBase64UserInfoPreservesSlashPlusAndPadding() throws {
        let token = Data("user:???>x".utf8).base64EncodedString()
        XCTAssertTrue(["/", "+", "="].allSatisfy(token.contains))
        for value in [token, token.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")] {
            let node = try SubscriptionParser.parseLine("socks://\(value)@example.com:1080")
            XCTAssertEqual(node.username, "user")
            XCTAssertEqual(node.password, "???>x")
        }
        for value in ["Og==", "Og%3D%3D"] {
            let node = try SubscriptionParser.parseLine("socks://\(value)@192.0.2.10:1080")
            XCTAssertNil(node.username)
            XCTAssertNil(node.password)
        }
    }

    func testSOCKSPlainCredentialsUseLastAtAndFirstColon() throws {
        for prefix in SubscriptionParser.socksPrefixes {
            let node = try SubscriptionParser.parseLine("\(prefix)user:p@ss:word@example.com:1080")
            XCTAssertEqual(node.username, "user")
            XCTAssertEqual(node.password, "p@ss:word")
            XCTAssertEqual(node.server, "example.com")
            let anonymous = try SubscriptionParser.parseLine("\(prefix)example.com:1081")
            XCTAssertNil(anonymous.username)
            XCTAssertNil(anonymous.password)
        }
        let encoded = try SubscriptionParser.parseLine("socks5h://user%3Aname:p%40ss%3A%2541@example.com:1080")
        XCTAssertEqual(encoded.username, "user:name")
        XCTAssertEqual(encoded.password, "p@ss:%41")
        let literal = Data("user:literal%41".utf8).base64EncodedString()
        XCTAssertEqual(try SubscriptionParser.parseLine("socks://\(literal)@example.com:1080").password, "literal%41")
    }

    func testWrappedSOCKSLinkIsJoinedBeforeParsing() throws {
        let token = Data("user:pass@example.com:1080".utf8).base64EncodedString()
        let first = token.prefix(12)
        let remainder = token.dropFirst(12)
        let text = "# Example subscription\nsocks://\(first)\n  \(remainder.prefix(8)) \t\(remainder.dropFirst(8))?obfs=none&remarks=US-Node\nsocks5h://192.0.2.20:1081#Second"
        let nodes = try SubscriptionParser.parse(text)
        XCTAssertEqual(nodes.map(\.name), ["US-Node", "Second"])
        XCTAssertEqual(nodes[0].server, "example.com")
        XCTAssertEqual(nodes[0].username, "user")
        XCTAssertEqual(nodes[0].password, "pass")
        XCTAssertEqual(nodes[1].serverPort, 1081)
    }

    func testMalformedSOCKSEndpointsAreRejected() {
        for authority in ["example.com", "example.com:0", "example.com:65536", "example.com:noport",
                          "user:pass@2001:db8::1:1080", "user:pass@bad host:1080", "!!!notbase64"] {
            XCTAssertThrowsError(try SubscriptionParser.parseLine("socks://\(authority)"))
            let token = Data(authority.utf8).base64EncodedString()
            XCTAssertThrowsError(try SubscriptionParser.parseLine("socks://\(token)"))
        }
    }

    func testWholeBase64SOCKSBuildsValidatedConfiguration() throws {
        let token = Data("user:pass@example.com:1080".utf8).base64EncodedString()
        let node = try SubscriptionParser.parseLine("socks://\(token)?obfs=none&remarks=US-Node")
        try node.validate()
        let configuration = try SingboxConfigBuilder.makeConfiguration(inboundPort: 20_001, node: node)
        let outbound = try XCTUnwrap(configuration.outbounds.first)
        XCTAssertEqual(outbound["type"], .string("socks"))
        XCTAssertEqual(outbound["server"], .string("example.com"))
        XCTAssertEqual(outbound["server_port"], .number(1080))
        XCTAssertEqual(outbound["username"], .string("user"))
        XCTAssertEqual(outbound["password"], .string("pass"))
        XCTAssertEqual(try JSONDecoder().decode(SingboxConfiguration.self, from: configuration.encoded()), configuration)
    }

    func testIPv6HostDropsBrackets() throws {
        let node = try SubscriptionParser.parseLine("socks5://[2001:db8::1]:1080#v6")
        XCTAssertEqual(node.server, "2001:db8::1")
        XCTAssertNoThrow(try node.validate())
    }

    func testAnyTLSLine() throws {
        let node = try SubscriptionParser.parseLine("anytls://pa%3Ass@edge.example.com:8443/?sni=cdn.example.com&insecure=1#JP AnyTLS 01")
        XCTAssertEqual(node.type, .anytls)
        XCTAssertEqual(node.name, "JP AnyTLS 01")
        XCTAssertEqual(node.server, "edge.example.com")
        XCTAssertEqual(node.serverPort, 8443)
        XCTAssertEqual(node.password, "pa:ss")
        XCTAssertTrue(node.tls)
        XCTAssertEqual(node.serverName, "cdn.example.com")
        XCTAssertEqual(node.parameters["insecure"], "1")
        XCTAssertNoThrow(try node.validate())
    }

    func testAnyTLSWithoutPasswordIsRejected() {
        XCTAssertThrowsError(try SubscriptionParser.parseLine("anytls://edge.example.com:443#x"))
    }

    func testFragmentIsSplitBeforeURLParsingForEveryScheme() throws {
        let node = try SubscriptionParser.parseLine("trojan://secret@t.example:443?sni=t.example#香港 01 | 2x")
        XCTAssertEqual(node.name, "香港 01 | 2x")
        XCTAssertEqual(node.password, "secret")
    }

    /// 228 行、整体 Base64 且按 76 列折行的订阅（和用户的订阅同一格式），全部解析成功。
    func testWrappedBase64SubscriptionWithManySOCKSNodes() throws {
        let lines = (20001...20228).map { "socks://Og%3D%3D@192.0.2.6:\($0)#lan-\($0) edge-v6 \($0)" }
        let encoded = Data(lines.joined(separator: "\n").utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        XCTAssertTrue(encoded.contains("\n"))

        let nodes = try SubscriptionParser.parse(encoded)

        XCTAssertEqual(nodes.count, 228)
        XCTAssertTrue(nodes.allSatisfy { $0.type == .socks && $0.server == "192.0.2.6" && $0.username == nil })
        XCTAssertEqual(nodes.last?.name, "lan-20228 edge-v6 20228")
        XCTAssertEqual(Set(nodes.map(\.serverPort)).count, 228)
    }

    func testPlainTextSubscriptionIsNotMistakenForBase64() throws {
        let text = "socks://Og%3D%3D@192.0.2.6:20001#a b\nanytls://pw@h.example:443?sni=h.example#c d\n"
        XCTAssertEqual(try SubscriptionParser.parse(text).map(\.type), [.socks, .anytls])
    }

    // MARK: - Shadowsocks / SS2022

    /// 16 / 32 字节的 SS2022 密钥，Base64 里故意带 `+`、`/`、`=`。
    static let key16 = "++++////AQIDBAUGBwgJCg=="
    static let key32 = "++++////AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo="
    static let key32b = "ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CBgoM="

    func testSS2022PlainKeysWithSlashPlusAndPadding() throws {
        let cases: [(method: String, key: String)] = [
            ("2022-blake3-aes-128-gcm", Self.key16),
            ("2022-blake3-aes-256-gcm", Self.key32),
            ("2022-blake3-chacha20-poly1305", Self.key32),
        ]
        for (method, key) in cases {
            let node = try SubscriptionParser.parseLine("ss://\(method):\(key)@ss.example.com:8388#🇯🇵 SS2022 \(method)")
            XCTAssertEqual(node.type, .shadowsocks, method)
            XCTAssertEqual(node.method, method)
            XCTAssertEqual(node.password, key, "密钥里的 / + = 要原样保留")
            XCTAssertEqual(node.server, "ss.example.com")
            XCTAssertEqual(node.serverPort, 8388)
            XCTAssertEqual(node.name, "🇯🇵 SS2022 \(method)")
            XCTAssertNoThrow(try node.validate())
        }
    }

    func testSS2022MultiUserEIHWithIPv6() throws {
        let node = try SubscriptionParser.parseLine("ss://2022-blake3-aes-256-gcm:\(Self.key32):\(Self.key32b)@[2001:db8::1]:8388#eih")
        XCTAssertEqual(node.method, "2022-blake3-aes-256-gcm")
        XCTAssertEqual(node.password, "\(Self.key32):\(Self.key32b)", "EIH 的 serverKey:userKey 整体是密码")
        XCTAssertEqual(node.server, "2001:db8::1")
        XCTAssertEqual(node.serverPort, 8388)
    }

    func testSS2022PercentEncodedUserInfo() throws {
        let encoded = "2022-blake3-aes-256-gcm%3A" + Self.key32
            .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "=", with: "%3D")
        let node = try SubscriptionParser.parseLine("ss://\(encoded)@203.0.113.5:443/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com&uot=1#pct")
        XCTAssertEqual(node.method, "2022-blake3-aes-256-gcm")
        XCTAssertEqual(node.password, Self.key32)
        XCTAssertEqual(node.server, "203.0.113.5")
        XCTAssertEqual(node.serverPort, 443)
        XCTAssertEqual(node.parameters["plugin"], "obfs-local;obfs=http;obfs-host=cdn.example.com")
        XCTAssertEqual(node.parameters["uot"], "1")
        XCTAssertEqual(node.name, "pct")
    }

    func testSS2022SIP002Base64UserInfo() throws {
        let userInfo = Data("2022-blake3-aes-128-gcm:\(Self.key16)".utf8).base64EncodedString()
        for token in [userInfo, userInfo.replacingOccurrences(of: "=", with: ""),
                      userInfo.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")] {
            let node = try SubscriptionParser.parseLine("ss://\(token)@ss.example.com:8388/?plugin=#b64")
            XCTAssertEqual(node.method, "2022-blake3-aes-128-gcm", token)
            XCTAssertEqual(node.password, Self.key16, token)
            XCTAssertEqual(node.serverPort, 8388)
        }
    }

    func testSS2022WholeBase64LegacyFormat() throws {
        let whole = Data("2022-blake3-aes-128-gcm:\(Self.key16)@[2001:db8::2]:9443".utf8).base64EncodedString()
        let node = try SubscriptionParser.parseLine("ss://\(whole)#旧格式 01")
        XCTAssertEqual(node.method, "2022-blake3-aes-128-gcm")
        XCTAssertEqual(node.password, Self.key16)
        XCTAssertEqual(node.server, "2001:db8::2")
        XCTAssertEqual(node.serverPort, 9443)
        XCTAssertEqual(node.name, "旧格式 01")
    }

    func testClassicShadowsocksFormatsStillWork() throws {
        let sip002 = try SubscriptionParser.parseLine("ss://\(Data("aes-128-gcm:p@ss:w0rd".utf8).base64EncodedString())@s.example:8388#a")
        XCTAssertEqual(sip002.method, "aes-128-gcm")
        XCTAssertEqual(sip002.password, "p@ss:w0rd")
        let legacy = try SubscriptionParser.parseLine("ss://\(Data("chacha20-ietf-poly1305:p@ss@s.example:8389".utf8).base64EncodedString())")
        XCTAssertEqual(legacy.method, "chacha20-ietf-poly1305")
        XCTAssertEqual(legacy.password, "p@ss", "按最后一个 @ 切")
        XCTAssertEqual(legacy.server, "s.example")
        XCTAssertEqual(legacy.name, "s.example", "没有名字时用主机名")
        let plain = try SubscriptionParser.parseLine("shadowsocks://aes-256-gcm:secret@s.example:8390#c")
        XCTAssertEqual(plain.password, "secret")
        XCTAssertEqual(plain.serverPort, 8390)
    }

    func testMalformedShadowsocksLinesAreRejected() {
        for line in [
            "ss://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com#no-port",
            "ss://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:70000",
            "ss://2022-blake3-aes-128-gcm:\(Self.key16)@2001:db8::1:8388",
            "ss://:\(Self.key16)@ss.example.com:8388",
            "ss://2022-blake3-aes-128-gcm:@ss.example.com:8388",
            "ss://@ss.example.com:8388",
            "ss://!!!notbase64",
        ] {
            XCTAssertThrowsError(try SubscriptionParser.parseLine(line), line)
        }
    }

    func testSubscriptionMixingSS2022AndOtherSchemes() throws {
        let text = [
            "ss://2022-blake3-aes-256-gcm:\(Self.key32)@ss.example.com:8388#a",
            "trojan://secret@t.example:443?sni=t.example#b",
            "ss://\(Data("2022-blake3-chacha20-poly1305:\(Self.key32)".utf8).base64EncodedString())@ss.example.com:8389#c",
        ].joined(separator: "\n")
        let nodes = try SubscriptionParser.parse(Data(text.utf8).base64EncodedString())
        XCTAssertEqual(nodes.map(\.type), [.shadowsocks, .trojan, .shadowsocks])
        XCTAssertEqual(nodes.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(nodes.last?.method, "2022-blake3-chacha20-poly1305")
    }

    /// URL-safe（`-`、`_`）或省略 `=` 的 SS2022 密钥统一成标准 Base64（sing-box 只认这种）。
    func testSS2022KeysAreNormalizedToStandardBase64() throws {
        let urlSafe16 = "----____AQIDBAUGBwgJCg"        // key16 的 URL-safe、无补齐写法
        let unpadded32 = String(Self.key32.dropLast())   // 去掉末尾的 =
        let node = try SubscriptionParser.parseLine("ss://2022-blake3-aes-128-gcm:\(urlSafe16)@ss.example.com:8388#u")
        XCTAssertEqual(node.password, Self.key16)
        let eih = try SubscriptionParser.parseLine("ss://2022-blake3-aes-256-gcm:\(unpadded32):\(Self.key32b.replacingOccurrences(of: "+", with: "-"))@ss.example.com:8388#e")
        XCTAssertEqual(eih.password, "\(Self.key32):\(Self.key32b)", "EIH 的每一段分别规范化")
        let sip002 = Data("2022-blake3-chacha20-poly1305:\(unpadded32)".utf8).base64EncodedString()
        XCTAssertEqual(try SubscriptionParser.parseLine("ss://\(sip002)@ss.example.com:8388#b").password, Self.key32)

        XCTAssertEqual(SubscriptionParser.normalizedShadowsocksPassword(Self.key16, method: "2022-blake3-aes-128-gcm"), Self.key16, "标准写法不变")
        XCTAssertEqual(SubscriptionParser.normalizedShadowsocksPassword("not base64!", method: "2022-blake3-aes-128-gcm"), "not base64!", "解不开的原样保留")
        XCTAssertEqual(SubscriptionParser.normalizedShadowsocksPassword("my-pass_word", method: "aes-128-gcm"), "my-pass_word", "其它加密方式的密码不动")
        let classic = try SubscriptionParser.parseLine("ss://aes-256-gcm:my-pass_word@s.example:8388#c")
        XCTAssertEqual(classic.password, "my-pass_word")
    }

    func testSS2022Prefix() throws {
        for prefix in ["ss2022://", "SS2022://", "shadowsocks://", "ss://"] {
            let node = try SubscriptionParser.parseLine("\(prefix)2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:8388#p")
            XCTAssertEqual(node.type, .shadowsocks, prefix)
            XCTAssertEqual(node.method, "2022-blake3-aes-128-gcm", prefix)
            XCTAssertEqual(node.password, Self.key16, prefix)
        }
        let userInfo = Data("2022-blake3-aes-256-gcm:\(Self.key32)".utf8).base64EncodedString()
        XCTAssertEqual(try SubscriptionParser.parseLine("ss2022://\(userInfo)@[2001:db8::3]:443#v6").server, "2001:db8::3")
        XCTAssertEqual(try SubscriptionParser.parse("ss2022://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:8388#a").count, 1)
    }

    /// 机场订阅里混着 hysteria2 / tuic / ssr：跳过这些行，SS2022 和 VLESS 节点照常导入。
    func testMixedSubscriptionSkipsUnsupportedSchemes() throws {
        let lines = [
            "hysteria2://pw@h.example:443?sni=h.example#hy2-01",
            "ss://2022-blake3-aes-256-gcm:\(Self.key32)@ss.example.com:8388#🇯🇵 SS2022",
            "tuic://uuid:pw@t.example:443#tuic",
            "vless://00000000-0000-0000-0000-000000000001@v.example:443?security=tls&type=ws#vless",
            "ssr://c3NyLmV4YW1wbGU6ODM4ODpvcmlnaW46YWVzLTI1Ni1jZmI6cGxhaW46Y0hjOg",
            "hysteria2://pw@h2.example:443#hy2-02",
        ]
        for content in [lines.joined(separator: "\n"), Data(lines.joined(separator: "\n").utf8).base64EncodedString()] {
            let result = try SubscriptionParser.parseResult(content)
            XCTAssertEqual(result.nodes.map(\.name), ["🇯🇵 SS2022", "vless"])
            XCTAssertEqual(result.skippedSchemes, ["hysteria2": 2, "tuic": 1, "ssr": 1])
            XCTAssertEqual(result.skippedCount, 4)
            XCTAssertEqual(try SubscriptionParser.parse(content).map(\.type), [.shadowsocks, .vless])
        }

        // 全是不支持的协议：报第一个。
        XCTAssertThrowsError(try SubscriptionParser.parse("tuic://a@t.example:443#a\nhysteria2://b@h.example:443#b")) {
            XCTAssertEqual($0 as? SubscriptionParseError, .unsupportedScheme("tuic"))
        }
        // 支持的协议写错了仍然整份报错（不悄悄丢节点）。
        XCTAssertThrowsError(try SubscriptionParser.parse("hysteria2://b@h.example:443#b\nss://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com#no-port")) {
            guard case .invalidLine = $0 as? SubscriptionParseError else { return XCTFail("\($0)") }
        }
    }

    // MARK: - 重复的 query key

    /// 同一个参数出现两次（订阅生成器的 bug 很常见）：不崩溃，取第一个。
    func testDuplicateQueryKeysKeepFirstValue() throws {
        let vless = try SubscriptionParser.parseLine(
            "vless://00000000-0000-0000-0000-000000000001@v.example:443?security=tls&sni=a.example&sni=b.example&type=ws&type=grpc&path=%2Fa&path=%2Fb&flag#dup"
        )
        XCTAssertEqual(vless.serverName, "a.example")
        XCTAssertEqual(vless.transport, "ws")
        XCTAssertEqual(vless.transportPath, "/a")
        XCTAssertEqual(vless.parameters["sni"], "a.example")
        XCTAssertNil(vless.parameters["flag"], "没有值的参数忽略")
        XCTAssertEqual(vless.name, "dup")

        XCTAssertEqual(try SubscriptionParser.parseLine("trojan://secret@t.example:443?sni=a.example&sni=b.example#t").serverName, "a.example")
        XCTAssertEqual(try SubscriptionParser.parseLine("anytls://pw@a.example:443?sni=x.example&sni=y.example&insecure=1&insecure=0#a").parameters["insecure"], "1")
        XCTAssertEqual(try SubscriptionParser.parseLine("socks5://u:p@s.example:1080?x=1&x=2#s").parameters["x"], "1")

        // Shadowsocks 自己解析 query，规则一样。
        let ss = try SubscriptionParser.parseLine(
            "ss://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp&plugin=v2ray-plugin&uot=1&uot=0#ss"
        )
        XCTAssertEqual(ss.parameters["plugin"], "obfs-local;obfs=http")
        XCTAssertEqual(ss.parameters["uot"], "1")
    }

    func testSubscriptionWithDuplicateQueryKeysImports() throws {
        let text = [
            "vless://00000000-0000-0000-0000-000000000001@v.example:443?security=reality&pbk=k1&pbk=k2&sid=1&sid=2#r",
            "trojan://secret@t.example:443?type=ws&type=ws#t",
        ].joined(separator: "\n")
        let nodes = try SubscriptionParser.parse(Data(text.utf8).base64EncodedString())
        XCTAssertEqual(nodes.map(\.name), ["r", "t"])
        XCTAssertEqual(nodes.first?.parameters["pbk"], "k1")
    }

    // MARK: - 不支持的协议先按协议名判断

    /// 不支持的协议行常有 URL 解析不了的写法（端口带字母、主机名有空格、方括号没闭合）：不交给 URL 解析，
    /// 直接按协议名跳过，不让整份订阅失败。
    func testUnsupportedSchemeIsDetectedBeforeURLParsing() throws {
        let messy = "hysteria2://pw@h.exa mple:443/?obfs-password=a b#hy2 节点"
        for line in [messy, "hysteria2://pw@h.example:44a3#port", "hysteria2://pw@[2001:db8::1:443#v6"] {
            let body = String(line.split(separator: "#").first ?? "")
            XCTAssertNil(URL(string: body), "测试前提：\(body) 不是合法 URL")
            XCTAssertThrowsError(try SubscriptionParser.parseLine(line), line) {
                XCTAssertEqual($0 as? SubscriptionParseError, .unsupportedScheme("hysteria2"), line)
            }
        }
        XCTAssertThrowsError(try SubscriptionParser.parseLine("TUIC://u:p@t.example:443#t")) {
            XCTAssertEqual($0 as? SubscriptionParseError, .unsupportedScheme("tuic"), "协议名不区分大小写")
        }
        XCTAssertThrowsError(try SubscriptionParser.parseLine("vles://00000000-0000-0000-0000-000000000001@v.example:443#typo")) {
            XCTAssertEqual($0 as? SubscriptionParseError, .unsupportedScheme("vles"))
        }

        let result = try SubscriptionParser.parseResult([
            messy,
            "ss://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:8388#keep",
            "wireguard://key@[fe80::1:51820#wg",
        ].joined(separator: "\n"))
        XCTAssertEqual(result.nodes.map(\.name), ["keep"])
        XCTAssertEqual(result.skippedSchemes, ["hysteria2": 1, "wireguard": 1])

        // 没写协议的行不算「不支持的协议」，整份订阅照常报错，不会出现名字为空的跳过项。
        XCTAssertThrowsError(try SubscriptionParser.parseResult("ss://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:8388#a\n://empty")) {
            guard case .invalidLine = $0 as? SubscriptionParseError else { return XCTFail("\($0)") }
        }
    }

    /// 前置判断只放过「不支持的协议」：支持的协议写坏了、或者根本没有协议，仍然是 invalidLine。
    func testMalformedSupportedOrSchemelessLinesStayInvalid() {
        for line in ["vless://00000000-0000-0000-0000-000000000001@v.example:44a3#bad-port", "vless://@v.example:443#no-uuid",
                     "trojan://secret@t.example#no-port", "garbage", "://empty-scheme"] {
            XCTAssertThrowsError(try SubscriptionParser.parseLine(line), line) {
                guard case .invalidLine = $0 as? SubscriptionParseError else { return XCTFail("\(line): \($0)") }
            }
        }
    }

    // MARK: - Round 3：BOM、空参数、百分号解码

    func testUTF8BOMIsIgnored() throws {
        let line = "ss://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:8388#bom"
        XCTAssertEqual(try SubscriptionParser.parse("\u{FEFF}" + line).map(\.name), ["bom"], "明文订阅开头带 BOM")
        XCTAssertEqual(try SubscriptionParser.parse("\u{FEFF}" + Data(line.utf8).base64EncodedString()).count, 1, "Base64 订阅开头带 BOM")
        XCTAssertEqual(try SubscriptionParser.parse(Data(("\u{FEFF}" + line).utf8).base64EncodedString()).count, 1, "Base64 解开后开头带 BOM")
        XCTAssertEqual(SubscriptionParser.stripBOM("\u{FEFF}abc"), "abc")
        XCTAssertEqual(SubscriptionParser.stripBOM("abc"), "abc")
    }

    /// `sni=&serverName=b.example`：空参数不挡住后面的备用字段。
    func testEmptyParametersFallBackToAlternatives() throws {
        let vless = try SubscriptionParser.parseLine(
            "vless://00000000-0000-0000-0000-000000000001@v.example:443?security=tls&sni=&serverName=b.example&type=&network=ws&path=&host=&flow=#v"
        )
        XCTAssertEqual(vless.serverName, "b.example")
        XCTAssertEqual(vless.transport, "ws")
        XCTAssertNil(vless.transportPath)
        XCTAssertNil(vless.transportHost)
        XCTAssertNil(vless.flow)
        XCTAssertEqual(try SubscriptionParser.parseLine("trojan://pw@t.example:443?sni=&peer=p.example#t").serverName, "p.example")
        XCTAssertEqual(try SubscriptionParser.parseLine("anytls://pw@a.example:443?sni=%20&peer=&serverName=s.example#a").serverName, "s.example")

        let vmessJSON = #"{"v":"2","ps":"","add":"m.example","port":"443","id":"00000000-0000-0000-0000-000000000002","net":"","network":"ws","sni":"","host":"cdn.example","path":"","tls":"tls"}"#
        let vmess = try SubscriptionParser.parseLine("vmess://" + Data(vmessJSON.utf8).base64EncodedString() + "#片段名")
        XCTAssertEqual(vmess.name, "片段名", "ps 为空时用 # 后面的名字")
        XCTAssertEqual(vmess.transport, "ws")
        XCTAssertEqual(vmess.serverName, "cdn.example")
        XCTAssertNil(vmess.transportPath)
    }

    /// URLComponents.user 已经解码过一次：字面的 `%41` 不能再被解成 `A`。
    func testCredentialsAreDecodedOnlyOnce() throws {
        XCTAssertEqual(try SubscriptionParser.parseLine("trojan://p%2541ss@t.example:443#t").password, "p%41ss")
        XCTAssertEqual(try SubscriptionParser.parseLine("trojan://p%40ss%20word@t.example:443#t").password, "p@ss word")
        XCTAssertEqual(try SubscriptionParser.parseLine("vless://abc%2541@v.example:443#v").uuid, "abc%41")
    }

    /// trojan 密码里有 `:`：URLComponents 拆成了 user 和 password，要拼回去。
    func testTrojanPasswordWithColon() throws {
        XCTAssertEqual(try SubscriptionParser.parseLine("trojan://user:pa:ss@t.example:443#t").password, "user:pa:ss")
        XCTAssertEqual(try SubscriptionParser.parseLine("trojan://pw%3Aa@t.example:443#t").password, "pw:a")
    }

    func testUnsupportedSchemeStillReported() {
        XCTAssertThrowsError(try SubscriptionParser.parseLine("hysteria2://pw@h.example:443#x")) {
            XCTAssertEqual($0 as? SubscriptionParseError, .unsupportedScheme("hysteria2"))
        }
    }
}
