import Foundation
import SafarierCore

/// 已解析的两跳快照；凭据只在内存和 sing-box 的私有运行配置中使用。
public struct ResolvedProxyChain: Equatable, Sendable {
    /// 生成配置时使用的前置记录，供测试结束后核验引用是否仍然有效。
    public let upstream: ProxyChainEntry
    public let entry: [String: SingboxJSONValue]
    public let exit: [String: SingboxJSONValue]
    public let entryName: String
    public let exitName: String

    public func configuration(inboundPort: Int, logLevel: String = "warn") throws -> SingboxConfiguration {
        try SingboxConfigBuilder.makeConfiguration(inboundPort: inboundPort, outbound: exit, upstream: entry, logLevel: logLevel)
    }
}

public enum ProxyChainBuilder {
    public static func resolve(
        _ proxy: ProxySettings, in workspace: SafarierWorkspace, credentials: any CredentialStore
    ) throws -> ResolvedProxyChain? {
        guard let upstream = try workspace.validateProxyChain(proxy) else { return nil }
        let entry: [String: SingboxJSONValue]
        let name: String
        switch upstream {
        case .proxy(let saved):
            entry = try outbound(saved, credentials: credentials)
            name = saved.name
        case .node(let node):
            entry = SingboxConfigBuilder.makeOutbound(node)
            name = node.name
        case .custom(let json):
            entry = try CustomOutbound.parse(json)
            name = L10n.text("自定义前置")
        }
        return ResolvedProxyChain(upstream: upstream, entry: entry, exit: try outbound(proxy, credentials: credentials), entryName: name, exitName: proxy.name)
    }

    static func outbound(_ proxy: ProxySettings, credentials: any CredentialStore) throws -> [String: SingboxJSONValue] {
        try proxy.validate()
        var value: [String: SingboxJSONValue] = [
            "type": .string(proxy.kind == .socks5 ? "socks" : "http"),
            "server": .string(proxy.host.withoutIPv6Brackets), "server_port": .number(proxy.port),
        ]
        if proxy.kind == .socks5 {
            value["version"] = .string("5")
            value["network"] = .string("tcp")
        }
        if let username = proxy.username, !username.isEmpty {
            guard let password = try credentials.password(forKey: proxy.credentialKey), !password.isEmpty else {
                throw ProxyConnectionError.missingPassword
            }
            value["username"] = .string(username)
            value["password"] = .string(password)
        }
        return value
    }
}

public extension ProxyConnectionTester {
    /// 测试和浏览使用同一份链路配置；取消或结束后清理独立的辅助进程与凭据文件。
    static func check(
        chain: ResolvedProxyChain,
        executableURL: URL = SingboxProcessManager.defaultExecutableURL,
        using tester: @escaping Test = { try await check(proxy: $0, password: $1) }
    ) async throws -> ProxyConnectionResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-chain-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manager = SingboxProcessManager(executableURL: executableURL, stateDirectory: directory)
        defer {
            manager.stopAll()
            try? FileManager.default.removeItem(at: directory)
        }
        let id = UUID()
        let startup = Task.detached {
            try Task.checkCancellation()
            try manager.start(profileID: id, chain: chain)
            let port = try manager.waitUntilReady(profileID: id)
            try Task.checkCancellation()
            return port
        }
        let port = try await withTaskCancellationHandler {
            try await startup.value
        } onCancel: {
            startup.cancel()
        }
        try Task.checkCancellation()
        let local = ProxySettings(name: L10n.text("链式代理测试"), kind: .socks5, host: "127.0.0.1", port: port)
        return try await tester(local, nil)
    }
}
