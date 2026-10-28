import Foundation
import WebKit
import SafarierCore

public enum WebViewConfigurationError: Error, Equatable {
    case proxyNotFound(UUID)
    case proxyMismatch(expected: UUID, got: UUID)
}

/// 把一个 profile 组装成 WKWebViewConfiguration，并如实记录每项能力的落实情况。
/// 只用公开 API；私有开关全部交给 `PrivacyProtectionAdapter`。
@MainActor
public struct WebViewConfigurationFactory {
    public struct Output {
        public let configuration: WKWebViewConfiguration
        public let extensionRuntime: (any WebExtensionRuntimeProtocol)?
        /// Runner 在创建 WebView 之后还会补上每个 WebView 上才能设置的项（机型像素比）。
        public var report: PrivacyCapabilityReport
    }

    public let dataStores: DataStoreManager
    public let credentials: any CredentialStore
    public let privacy: any PrivacyProtectionAdapter
    public let safariApplicationName: String?
    /// UA 里的 Safari 版本是怎么选出来的；nil 表示调用方直接给了 `safariApplicationName`。
    public let userAgentVersion: SafarierWebKitInfo.UserAgentVersion?
    public let engineBaseline: EngineBaselineDiagnostic
    public let extensionWorkspace: SafarierWorkspace?

    /// `dataStores`、`privacy` 传 nil 时用默认实现（默认参数里不能直接调 @MainActor 初始化器）。
    public init(
        dataStores: DataStoreManager? = nil,
        credentials: any CredentialStore,
        privacy: (any PrivacyProtectionAdapter)? = nil,
        userAgentVersion: SafarierWebKitInfo.UserAgentVersion? = SafarierWebKitInfo.userAgentSafariVersion(),
        engineBaseline: EngineBaselineDiagnostic = SafarierWebKitInfo.engineBaseline(),
        extensionWorkspace: SafarierWorkspace? = nil
    ) {
        self.init(
            dataStores: dataStores,
            credentials: credentials,
            privacy: privacy,
            safariApplicationName: userAgentVersion.flatMap { SafarierWebKitInfo.safariApplicationNameForUserAgent(safariVersion: $0.version) },
            userAgentVersion: userAgentVersion,
            engineBaseline: engineBaseline,
            extensionWorkspace: extensionWorkspace
        )
    }

    public init(
        dataStores: DataStoreManager? = nil,
        credentials: any CredentialStore,
        privacy: (any PrivacyProtectionAdapter)? = nil,
        safariApplicationName: String?,
        userAgentVersion: SafarierWebKitInfo.UserAgentVersion? = nil,
        engineBaseline: EngineBaselineDiagnostic = SafarierWebKitInfo.engineBaseline(),
        extensionWorkspace: SafarierWorkspace? = nil
    ) {
        self.dataStores = dataStores ?? DataStoreManager()
        self.credentials = credentials
        self.privacy = privacy ?? PublicAPIPrivacyAdapter()
        self.safariApplicationName = safariApplicationName
        self.userAgentVersion = userAgentVersion
        self.engineBaseline = engineBaseline
        self.extensionWorkspace = extensionWorkspace
    }

    /// - Parameters:
    ///   - proxy: profile.proxyID 指向的代理；profile 没配代理时传 nil。
    ///   - processLanguages: Runner 进程实际生效的 AppleLanguages，用来判断 `-AppleLanguages` 有没有带进来。
    public func make(
        profile: Profile,
        proxy: ProxySettings?,
        processLanguages: [String] = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
    ) throws -> Output {
        var report = PrivacyCapabilityReport(engineBaseline: engineBaseline)
        let baselineState: CapabilityState
        if engineBaseline.loadedWebKit == nil {
            baselineState = .unavailable(engineBaseline.note)
        } else if !engineBaseline.matchesEngine || engineBaseline.relationship == .unverified {
            baselineState = .unverified(engineBaseline.note)
        } else if engineBaseline.hasStagedEngineMismatch {
            baselineState = .degraded(engineBaseline.note)
        } else {
            baselineState = .active(engineBaseline.note)
        }
        report.set(baselineState, for: .engineBaseline)
        report.set(.unverified(PrivacyCapabilityReport.webAuthenticationBoundary), for: .webAuthentication)
        report.set(.notRequested, for: .legacyDOMEvents)
        let configuration = WKWebViewConfiguration()
        let extensionMount: (runtime: (any WebExtensionRuntimeProtocol)?, state: CapabilityState)
        if let extensionWorkspace {
            extensionMount = WebExtensionSupport.attach(profile: profile, workspace: extensionWorkspace, to: configuration)
        } else {
            extensionMount = (nil, .notRequested)
        }
        report.set(extensionMount.state, for: .webExtensions)

        let store = dataStores.dataStore(for: profile)
        switch profile.mode {
        case .persistent:
            report.set(.active("WKWebsiteDataStore(forIdentifier: \(profile.id.uuidString))"), for: .dataIsolation)
        case .ephemeral:
            report.set(.active("WKWebsiteDataStore.nonPersistent()，窗口关闭即销毁"), for: .dataIsolation)
        }

        if let proxyID = profile.proxyID {
            guard let proxy else { throw WebViewConfigurationError.proxyNotFound(proxyID) }
            guard proxy.id == proxyID else { throw WebViewConfigurationError.proxyMismatch(expected: proxyID, got: proxy.id) }
            let password = proxy.username == nil ? nil : try credentials.password(forKey: proxy.credentialKey)
            try ProxyConfigurationBuilder.apply(proxy, password: password, to: store)
            report.set(
                .active("\(proxy.kind.rawValue) \(proxy.host):\(proxy.port)（DNS/WebRTC 泄漏见 M0-3、M0-4）"),
                for: .proxy
            )
        } else {
            ProxyConfigurationBuilder.applyNone(to: store)
            report.set(.notRequested, for: .proxy)
        }
        configuration.websiteDataStore = store

        // 和 Safari 默认一致的公开设置（WKWebView 默认不同，网页查得出来）：元素全屏（document.fullscreenEnabled）、
        // 有声媒体要用户操作才自动播放（Safari「停止播放有声媒体」）、已知支持 HTTPS 的网站自动升级。
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.upgradeKnownHostsToHTTPS = true

        if profile.languages.isEmpty {
            report.set(.notRequested, for: .languages)
        } else if processLanguages == profile.languages {
            // M0-1（2026-10-24，macOS 15.7.3 / WebKit 20621.3.11）：主线程、Worker 的 navigator.language 和 Accept-Language 都生效。
            report.set(.active("-AppleLanguages 进程参数（navigator.language 和 Accept-Language 已实测生效）"), for: .languages)
        } else {
            report.set(.unavailable("Runner 进程的 AppleLanguages 是 \(processLanguages)，不是 \(profile.languages)"), for: .languages)
        }

        if profile.timeZoneIdentifier != nil {
            // M0-2（2026-10-24 实测）：TZ 只改 Runner 进程，WebContent 进程仍是系统时区。
            // 开启 --spi tz 时由 SPIPrivacyAdapter 用引擎层覆盖改写这一项（M0-8 已实测生效）。
            report.set(.unavailable("TZ 传不到 WebContent，网页仍是系统时区；开启 --spi tz 使用引擎层覆盖"), for: .timeZone)
        } else {
            report.set(.notRequested, for: .timeZone)
        }

        if let safariApplicationName {
            configuration.applicationNameForUserAgent = safariApplicationName
            let note = userAgentVersion.map { "；\($0.note)" } ?? ""
            let text = "applicationNameForUserAgent = \(safariApplicationName)\(note)"
            report.set(userAgentVersion?.matchesEngine == false ? .degraded(text) : .active(text), for: .safariUserAgent)
        } else {
            report.set(.unavailable("找不到 /Applications/Safari.app，保持 WebKit 默认 UA"), for: .safariUserAgent)
        }

        report.set(
            profile.deviceModel == nil ? .notRequested : .unverified("像素比要在 WebView 创建后设置"),
            for: .deviceModel
        )
        report.set(
            profile.deviceModel == nil ? .notRequested : .unverified("屏幕能力由 Runner 在创建 WebView 前安装"),
            for: .displayCapabilities
        )
        privacy.apply(to: configuration, for: profile, report: &report)
        return Output(configuration: configuration, extensionRuntime: extensionMount.runtime, report: report)
    }
}

extension ProxyConfigurationBuilder {
    /// 显式清空，避免沿用 data store 上残留的配置。
    @MainActor
    static func applyNone(to store: WKWebsiteDataStore) {
        store.proxyConfigurations = []
    }
}
