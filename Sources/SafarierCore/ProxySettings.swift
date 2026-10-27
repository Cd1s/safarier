import Foundation

public enum ProxyKind: String, Codable, Sendable, CaseIterable {
    case socks5
    case httpConnect
}

/// 代理配置。密码绝不放在这里，只通过 `credentialKey` 到 `CredentialStore` 中取。
public struct ProxySettings: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    public var username: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProxyKind,
        host: String,
        port: Int,
        username: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
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
