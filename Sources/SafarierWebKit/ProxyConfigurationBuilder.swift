import Network
import WebKit
import SafarierCore

public enum ProxyConfigurationError: Error, Equatable {
    case invalid(ProxyValidationError)
    case missingPassword(username: String)
    case unresolvedChain
}

public enum ProxyConfigurationBuilder {
    /// 把 ProxySettings（+ 从 CredentialStore 取出的密码）转换成 WebKit 的 ProxyConfiguration。
    public static func makeConfiguration(for settings: ProxySettings, password: String?) throws -> ProxyConfiguration {
        // 带前置的代理只能由 Runner 转为本地 sing-box 入口，不能被其他调用方误当单跳使用。
        guard settings.upstream == nil else { throw ProxyConfigurationError.unresolvedChain }
        do {
            try settings.validate()
        } catch let error as ProxyValidationError {
            throw ProxyConfigurationError.invalid(error)
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(settings.host),
            port: NWEndpoint.Port(rawValue: UInt16(settings.port))!
        )

        var config: ProxyConfiguration
        switch settings.kind {
        case .socks5:
            config = ProxyConfiguration(socksv5Proxy: endpoint)
        case .httpConnect:
            config = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        }
        config.allowFailover = false

        if let username = settings.username, !username.isEmpty {
            guard let password else {
                throw ProxyConfigurationError.missingPassword(username: username)
            }
            config.applyCredential(username: username, password: password)
        }
        return config
    }

    /// settings 为 nil 时清空代理；否则设置为单个代理。
    @MainActor
    public static func apply(_ settings: ProxySettings?, password: String?, to store: WKWebsiteDataStore) throws {
        guard let settings else {
            store.proxyConfigurations = []
            return
        }
        store.proxyConfigurations = [try makeConfiguration(for: settings, password: password)]
    }
}
