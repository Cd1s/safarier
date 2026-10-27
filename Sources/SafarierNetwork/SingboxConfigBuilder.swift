import Foundation
import SafarierCore

/// A small Codable JSON value used for sing-box's deliberately extensible schema.
public indirect enum SingboxJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)
    case bool(Bool)
    case object([String: SingboxJSONValue])
    case array([SingboxJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let value = try? single.decode(Bool.self) { self = .bool(value) }
        else if let value = try? single.decode(Int.self) { self = .number(value) }
        else if let value = try? single.decode(String.self) { self = .string(value) }
        else if let value = try? single.decode([String: SingboxJSONValue].self) { self = .object(value) }
        else if let value = try? single.decode([SingboxJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let value): try single.encode(value)
        case .number(let value): try single.encode(value)
        case .bool(let value): try single.encode(value)
        case .object(let value): try single.encode(value)
        case .array(let value): try single.encode(value)
        case .null: try single.encodeNil()
        }
    }
}

public struct SingboxConfiguration: Codable, Equatable, Sendable {
    public var log: [String: SingboxJSONValue]
    public var inbounds: [[String: SingboxJSONValue]]
    public var outbounds: [[String: SingboxJSONValue]]
    public var route: [String: SingboxJSONValue]

    public init(
        log: [String: SingboxJSONValue] = ["level": .string("info")],
        inbounds: [[String: SingboxJSONValue]],
        outbounds: [[String: SingboxJSONValue]],
        route: [String: SingboxJSONValue]
    ) {
        self.log = log
        self.inbounds = inbounds
        self.outbounds = outbounds
        self.route = route
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public enum SingboxConfigError: Error, Equatable {
    case invalidInboundPort(Int)
    case invalidNode(SubscriptionNodeValidationError)
}

/// 最小的 sing-box 配置：一个本地 SOCKS5 入站，一个节点出站；路由全部走节点（`direct` 只是保留的出站，没有规则用它，
/// 节点断了不会退回直连）。字段按 sing-box 1.12+ 的格式（1.14.4 实测 `sing-box check` 通过），
/// 不再用 1.13 起移除的入站 `sniff` 和不存在的 `udp` 字段。
public struct SingboxConfigBuilder: Sendable {
    public static let defaultInboundAddress = "127.0.0.1"
    public static let proxyTag = "proxy"
    public static let directTag = "direct"

    public static func makeConfiguration(
        inboundPort: Int,
        node: SubscriptionNode,
        inboundAddress: String = defaultInboundAddress,
        logLevel: String = "info"
    ) throws -> SingboxConfiguration {
        guard (1...65535).contains(inboundPort) else { throw SingboxConfigError.invalidInboundPort(inboundPort) }
        do { try node.validate() } catch let error as SubscriptionNodeValidationError {
            throw SingboxConfigError.invalidNode(error)
        }

        let inbound: [String: SingboxJSONValue] = [
            "type": .string("socks"),
            "tag": .string("socks-in"),
            "listen": .string(inboundAddress),
            "listen_port": .number(inboundPort),
        ]

        return SingboxConfiguration(
            log: ["level": .string(logLevel)],
            inbounds: [inbound],
            outbounds: [makeOutbound(node), ["type": .string("direct"), "tag": .string(directTag)]],
            route: ["final": .string(proxyTag)]
        )
    }

    public static func build(inboundPort: Int, node: SubscriptionNode) throws -> Data {
        try makeConfiguration(inboundPort: inboundPort, node: node).encoded()
    }

    public static func makeConfig(inboundPort: Int, node: SubscriptionNode) throws -> Data {
        try build(inboundPort: inboundPort, node: node)
    }

    public func build(inboundPort: Int, node: SubscriptionNode) throws -> Data {
        try Self.build(inboundPort: inboundPort, node: node)
    }

    private static func makeOutbound(_ node: SubscriptionNode) -> [String: SingboxJSONValue] {
        var result: [String: SingboxJSONValue] = [
            "type": .string(node.type.singboxType),
            "tag": .string(proxyTag),
            "server": .string(node.server),
            "server_port": .number(node.serverPort),
        ]
        switch node.type {
        case .vless, .vmess:
            if let uuid = node.uuid { result["uuid"] = .string(uuid) }
            if let flow = node.flow { result["flow"] = .string(flow) }
            if node.type == .vmess, let alterID = node.alterID { result["alter_id"] = .number(alterID) }
            if node.type == .vmess, let method = node.method { result["security"] = .string(method) }
        case .trojan:
            if let password = node.password { result["password"] = .string(password) }
        case .shadowsocks:
            // SS2022（2022-blake3-*）多用户的 `serverKey:userKey` 整体就是 password。解析时已经把密钥规范成标准 Base64，
            // 以前保存的节点可能还是 URL-safe / 没补齐的写法：这里再规范化一次。
            if let method = node.method { result["method"] = .string(method) }
            if let password = node.password {
                result["password"] = .string(node.method.map { SubscriptionParser.normalizedShadowsocksPassword(password, method: $0) } ?? password)
            }
            // SIP002 插件：`plugin=obfs-local;obfs=http;obfs-host=example.com`，第一个 `;` 前是插件名。
            if let plugin = node.parameters["plugin"], !plugin.isEmpty {
                // `plugin=%3B`（只有一个分号）split 后为空：插件名为空时整个插件都不写（之前会数组越界崩溃）。
                let parts = plugin.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let pluginName = parts[0].trimmingCharacters(in: .whitespaces)
                if !pluginName.isEmpty {
                    result["plugin"] = .string(pluginName == "simple-obfs" ? "obfs-local" : pluginName)
                    if parts.count > 1, !parts[1].isEmpty { result["plugin_opts"] = .string(parts[1]) }
                }
            }
            if node.parameters["uot"].map({ ["1", "true"].contains($0.lowercased()) }) == true {
                result["udp_over_tcp"] = .bool(true)
            }
        case .socks:
            result["version"] = .string("5")
            if let username = node.username, !username.isEmpty { result["username"] = .string(username) }
            if let password = node.password, !password.isEmpty { result["password"] = .string(password) }
        case .anytls:
            if let password = node.password { result["password"] = .string(password) }
        }

        // AnyTLS 没有不带 TLS 的形式。
        if node.tls || node.type == .anytls || node.reality != nil {
            var tls: [String: SingboxJSONValue] = ["enabled": .bool(true)]
            if let serverName = node.serverName { tls["server_name"] = .string(serverName) }
            if node.allowsInsecureTLS { tls["insecure"] = .bool(true) }
            // `alpn=h2,http/1.1`（百分号已解码）。
            let alpn = (node.parameters["alpn"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !alpn.isEmpty { tls["alpn"] = .array(alpn.map { .string($0) }) }
            if let reality = node.reality {
                var object: [String: SingboxJSONValue] = ["enabled": .bool(true), "public_key": .string(reality.publicKey)]
                if let shortID = reality.shortID { object["short_id"] = .string(shortID) }
                tls["reality"] = .object(object)
            }
            // sing-box 的 Reality 客户端必须开 uTLS；链接没给指纹时用 chrome（和 Xray 客户端的默认一致）。
            if let fingerprint = node.tlsFingerprint ?? (node.reality != nil ? "chrome" : nil) {
                tls["utls"] = .object(["enabled": .bool(true), "fingerprint": .string(fingerprint)])
            }
            result["tls"] = .object(tls)
        }
        if let transport = makeTransport(node) { result["transport"] = .object(transport) }
        return result
    }

    /// 订阅里的传输方式（Xray 的 `type` / `net`）→ sing-box 的 transport。`tcp` / `raw` 就是不加传输层，
    /// sing-box 没有这个类型（写了会报 unknown transport type）；各类型的字段名按 sing-box 1.14.4 `check` 实测。
    static func makeTransport(_ node: SubscriptionNode) -> [String: SingboxJSONValue]? {
        guard let raw = node.transport?.lowercased(), !["", "tcp", "raw", "none"].contains(raw) else { return nil }
        let host = node.transportHost.flatMap { $0.isEmpty ? nil : $0 }
        let path = node.transportPath.flatMap { $0.isEmpty ? nil : $0 }
        switch raw {
        case "ws", "websocket":
            var object: [String: SingboxJSONValue] = ["type": .string("ws")]
            if var path {
                // Xray 的 `/path?ed=2048`：WebSocket 早期数据，sing-box 用单独的字段。只拿走合法的 ed 参数（1…UInt32.max），
                // 路径里其它查询参数原样保留。
                if let question = path.firstIndex(of: "?") {
                    var kept: [Substring] = []
                    var earlyData: Int?
                    for item in path[path.index(after: question)...].split(separator: "&") {
                        if earlyData == nil, item.hasPrefix("ed="), let size = Int(item.dropFirst(3)), size > 0, size <= Int(UInt32.max) {
                            earlyData = size
                        } else {
                            kept.append(item)
                        }
                    }
                    if let earlyData {
                        path = String(path[..<question]) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))
                        object["max_early_data"] = .number(earlyData)
                        object["early_data_header_name"] = .string("Sec-WebSocket-Protocol")
                    }
                }
                object["path"] = .string(path)
            }
            if let host { object["headers"] = .object(["Host": .string(host)]) }
            return object
        case "h2", "http":
            var object: [String: SingboxJSONValue] = ["type": .string("http")]
            if let path { object["path"] = .string(path) }
            if let host {
                object["host"] = .array(host.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
            }
            return object
        case "grpc":
            var object: [String: SingboxJSONValue] = ["type": .string("grpc")]
            if let name = node.parameters["serviceName"] ?? node.parameters["service_name"] ?? path, !name.isEmpty {
                object["service_name"] = .string(name)
            }
            return object
        case "httpupgrade":
            var object: [String: SingboxJSONValue] = ["type": .string("httpupgrade")]
            if let path { object["path"] = .string(path) }
            if let host { object["host"] = .string(host) }
            return object
        default:
            // quic 等原样交给 sing-box；不支持的类型（如 xhttp）由 sing-box 启动时报错，不会悄悄退回直连。
            return ["type": .string(raw)]
        }
    }
}

private extension SubscriptionNodeType {
    var singboxType: String {
        switch self {
        case .vless: return "vless"
        case .vmess: return "vmess"
        case .trojan: return "trojan"
        case .shadowsocks: return "shadowsocks"
        case .socks: return "socks"
        case .anytls: return "anytls"
        }
    }
}

private extension SubscriptionNode {
    /// VLESS Reality：`security=reality&pbk=公钥&sid=短 ID`（只有 pbk 也算）。
    var reality: (publicKey: String, shortID: String?)? {
        guard type == .vless else { return nil }
        let publicKey = parameters["pbk"] ?? parameters["publicKey"] ?? parameters["public_key"]
        guard parameters["security"]?.lowercased() == "reality" || publicKey?.isEmpty == false,
              let publicKey, !publicKey.isEmpty else { return nil }
        let shortID = parameters["sid"] ?? parameters["shortId"] ?? parameters["short_id"]
        return (publicKey, shortID.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// uTLS 指纹（`fp=chrome`）。
    var tlsFingerprint: String? {
        guard let value = parameters["fp"] ?? parameters["fingerprint"], !value.isEmpty, value.lowercased() != "none" else { return nil }
        return value.lowercased()
    }

    /// 节点链接里显式要求跳过证书校验（`insecure=1` / `allowInsecure=1`）。
    var allowsInsecureTLS: Bool {
        ["insecure", "allowInsecure", "allow_insecure"].contains { key in
            guard let value = parameters[key]?.lowercased() else { return false }
            return value == "1" || value == "true"
        }
    }
}
