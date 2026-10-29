import Foundation

/// Protocols understood by the subscription parser and sing-box bridge.
public enum SubscriptionNodeType: String, Codable, Sendable, CaseIterable {
    case vless
    case vmess
    case trojan
    case shadowsocks
    case socks
    case anytls
}

/// A proxy node cached from a subscription.
public struct SubscriptionNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var type: SubscriptionNodeType
    public var server: String
    public var serverPort: Int
    public var uuid: String?
    /// SOCKS 认证用户名；其它协议不用。
    public var username: String?
    public var password: String?
    public var method: String?
    public var tls: Bool
    public var serverName: String?
    public var transport: String?
    public var transportPath: String?
    public var transportHost: String?
    public var flow: String?
    public var alterID: Int?
    /// Protocol-specific values retained from the URI query string.
    public var parameters: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        type: SubscriptionNodeType,
        server: String,
        serverPort: Int,
        uuid: String? = nil,
        username: String? = nil,
        password: String? = nil,
        method: String? = nil,
        tls: Bool = false,
        serverName: String? = nil,
        transport: String? = nil,
        transportPath: String? = nil,
        transportHost: String? = nil,
        flow: String? = nil,
        alterID: Int? = nil,
        parameters: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.server = server
        self.serverPort = serverPort
        self.uuid = uuid
        self.username = username
        self.password = password
        self.method = method
        self.tls = tls
        self.serverName = serverName
        self.transport = transport
        self.transportPath = transportPath
        self.transportHost = transportHost
        self.flow = flow
        self.alterID = alterID
        self.parameters = parameters
    }

    /// sing-box 支持的 Shadowsocks 加密方式（含 SS2022 与旧式流/CFB/CTR）。
    public static let supportedShadowsocksMethods: Set<String> = [
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
        "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        "none",
        "aes-128-ctr", "aes-192-ctr", "aes-256-ctr",
        "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
        "rc4-md5", "chacha20-ietf", "xchacha20",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
    ]

    private static let shadowsocksMethodAliases: [String: String] = [
        "chacha20-poly1305": "chacha20-ietf-poly1305",
        "xchacha20-poly1305": "xchacha20-ietf-poly1305",
        "plain": "none",
        "dummy": "none",
        "aes-128-grm": "aes-128-gcm", "aes-128-gmc": "aes-128-gcm",
        "aes-192-grm": "aes-192-gcm", "aes-192-gmc": "aes-192-gcm",
        "aes-256-grm": "aes-256-gcm", "aes-256-gmc": "aes-256-gcm",
        "2022-blake3-aes-128-grm": "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-128-gmc": "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-256-grm": "2022-blake3-aes-256-gcm",
        "2022-blake3-aes-256-gmc": "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-ietf-poly1305": "2022-blake3-chacha20-poly1305",
    ]

    /// 去空白、转小写，并把订阅里常见的别名和 OCR / 手滑写错（`aes-128-grm` 等）改成 sing-box 认的名字。
    /// 不认识的名字原样（小写）返回，由调用方对照 `supportedShadowsocksMethods` 判断。
    public static func normalizedShadowsocksMethod(_ method: String) -> String {
        let lowered = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return shadowsocksMethodAliases[lowered] ?? lowered
    }

    public func validate() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SubscriptionNodeValidationError.emptyName }
        guard !server.isEmpty, !server.contains(where: { $0.isWhitespace }), !server.contains("/") else {
            throw SubscriptionNodeValidationError.invalidServer(server)
        }
        guard (1...65535).contains(serverPort) else {
            throw SubscriptionNodeValidationError.invalidPort(serverPort)
        }
        switch type {
        case .vless, .vmess:
            guard let uuid, !uuid.isEmpty else { throw SubscriptionNodeValidationError.missingIdentity }
        case .trojan, .anytls:
            guard let password, !password.isEmpty else { throw SubscriptionNodeValidationError.missingCredential }
        case .socks:
            // 用户名、密码都可以没有（无认证）；只给密码没给用户名的 SOCKS5 认证不成立。
            if password?.isEmpty == false, username?.isEmpty ?? true {
                throw SubscriptionNodeValidationError.missingIdentity
            }
        case .shadowsocks:
            guard let method, !method.isEmpty, let password, !password.isEmpty else {
                throw SubscriptionNodeValidationError.missingCredential
            }
            guard Self.supportedShadowsocksMethods.contains(Self.normalizedShadowsocksMethod(method)) else {
                throw SubscriptionNodeValidationError.unsupportedCipher(method)
            }
        }
    }
}

public typealias ProxyNode = SubscriptionNode
public typealias NodeProtocol = SubscriptionNodeType

public enum SubscriptionNodeValidationError: Error, Equatable {
    case emptyName
    case invalidServer(String)
    case invalidPort(Int)
    case missingIdentity
    case missingCredential
    case unsupportedCipher(String)
}

/// A subscription and its last successfully parsed node cache.
public struct Subscription: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL
    public let createdAt: Date
    public var updatedAt: Date?
    public var nodes: [SubscriptionNode]

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        nodes: [SubscriptionNode] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.nodes = nodes
    }

    public func validate() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SubscriptionValidationError.emptyName }
        guard trimmedName.count <= 128 else { throw SubscriptionValidationError.nameTooLong(trimmedName.count) }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "file"].contains(scheme) else {
            throw SubscriptionValidationError.unsupportedURLScheme(scheme)
        }
        if scheme != "file" && url.host == nil {
            throw SubscriptionValidationError.invalidURL(url.absoluteString)
        }
        for node in nodes { try node.validate() }
    }
}

public enum SubscriptionValidationError: Error, Equatable {
    case emptyName
    case nameTooLong(Int)
    case unsupportedURLScheme(String)
    case invalidURL(String)
}

extension Subscription: ValidatableRecord {}

public typealias SubscriptionRepository = RecordRepository<Subscription>

public extension RecordRepository where Record == Subscription {
    /// File layout: `directory/subscriptions.json`.
    static func subscriptions(in directory: URL) -> SubscriptionRepository {
        RecordRepository(store: JSONDocumentStore<Subscription>(
            fileURL: directory.appendingPathComponent("subscriptions.json")
        ))
    }
}
