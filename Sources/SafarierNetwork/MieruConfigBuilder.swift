import Foundation
import Darwin
import SafarierCore

public enum MieruError: Error, LocalizedError {
    case executableNotFound
    case invalidNode

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return L10n.text("找不到 Mieru。请使用包含 Mieru 的新版 Safarier，或用 SAFARIER_MIERU 指定可执行文件。")
        case .invalidNode: return L10n.text("Mieru 节点参数无效，请检查用户名、密码、传输和多路复用设置。")
        }
    }
}

/// sing-box 不实现 Mieru；官方客户端以独立前台进程提供本地 SOCKS5 入口。
public enum MieruConfigBuilder {
    public static func build(inboundPort: Int, node: SubscriptionNode) throws -> Data {
        guard node.type == .mieru, (1...65535).contains(inboundPort) else { throw MieruError.invalidNode }
        do { try node.validate() } catch { throw MieruError.invalidNode }
        let host = node.server.withoutIPv6Brackets
        var ipv4 = in_addr(), ipv6 = in6_addr()
        let isIP = inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
        let configuration: [String: SingboxJSONValue] = [
            "activeProfile": .string("proxy"),
            "rpcPort": .number(0),
            "socks5Port": .number(inboundPort),
            "socks5ListenLAN": .bool(false),
            "loggingLevel": .string("ERROR"),
            "profiles": .array([.object([
                "profileName": .string("proxy"),
                "user": .object(["name": .string(node.username!), "password": .string(node.password!)]),
                "servers": .array([.object([
                    isIP ? "ipAddress" : "domainName": .string(host),
                    "portBindings": .array([.object([
                        "port": .number(node.serverPort), "protocol": .string((node.transport ?? "TCP").uppercased())
                    ])])
                ])]),
                "multiplexing": .object(["level": .string(node.parameters["multiplexing"] ?? "MULTIPLEXING_DEFAULT")])
            ])])
        ]
        return try JSONEncoder().encode(configuration)
    }

    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledExecutable: URL? = SingboxProcessManager.bundledExecutableURL()?.deletingLastPathComponent().appendingPathComponent("mieru")
    ) -> URL? {
        if let override = environment["SAFARIER_MIERU"], !override.isEmpty { return URL(fileURLWithPath: override) }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/mieru" }
        return ([bundledExecutable?.path].compactMap { $0 } + ["/opt/homebrew/bin/mieru", "/usr/local/bin/mieru"] + paths)
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
