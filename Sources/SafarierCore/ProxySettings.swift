import Foundation

public enum ProxyKind: String, Codable, Sendable, CaseIterable {
    case socks5
    case httpConnect
}

/// 出口代理的前置连接。已保存代理按 ID 引用，订阅节点按名字匹配刷新后的记录。
public enum ProxyUpstream: Codable, Equatable, Sendable {
    case proxy(UUID)
    case node(subscriptionID: UUID, name: String)
    case custom(String)

    public var proxyID: UUID? {
        if case .proxy(let id) = self { return id }
        return nil
    }

    public var subscriptionID: UUID? {
        if case .node(let id, _) = self { return id }
        return nil
    }

    public var nodeName: String? {
        if case .node(_, let name) = self { return name }
        return nil
    }
}

public extension String {
    /// `[2001:db8::1]` → `2001:db8::1`。sing-box 配置和需要自己补括号的地方都要裸地址。
    var withoutIPv6Brackets: String {
        hasPrefix("[") && hasSuffix("]") ? String(dropFirst().dropLast()) : self
    }
}

/// 独立代理密码通过 `credentialKey` 从钥匙串读取；自定义前置 JSON 可能含认证信息。
public struct ProxySettings: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    public var username: String?
    public var upstream: ProxyUpstream?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProxyKind,
        host: String,
        port: Int,
        username: String? = nil,
        upstream: ProxyUpstream? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.upstream = upstream
    }

    /// 密码在 `CredentialStore` 中的 key。
    public var credentialKey: String {
        "proxy." + id.uuidString
    }

    public func validate() throws {
        if host.isEmpty {
            throw ProxyValidationError.emptyHost
        }
        if host.contains(where: { $0.isWhitespace }) || host.contains("://") || host.contains("/") {
            throw ProxyValidationError.invalidHost(host)
        }
        guard (1...65535).contains(port) else {
            throw ProxyValidationError.invalidPort(port)
        }
    }
}

public enum ProxyValidationError: Error, Equatable {
    case emptyHost
    case invalidHost(String)
    case invalidPort(Int)
}
