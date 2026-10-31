import Foundation
import WebKit
import SafarierCore
import SafarierObjCSupport

/// 原生引擎接口调用的诊断记录。Runner 把它打到 stderr（窗口模式进日志文件），探针把它放进 JSON。
public final class SPIDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let echo: ((String) -> Void)?

    public init(echo: ((String) -> Void)? = nil) {
        self.echo = echo
    }

    public static func standardError() -> SPIDiagnostics {
        SPIDiagnostics { FileHandle.standardError.write(Data("[spi] \($0)\n".utf8)) }
    }

    public var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func record(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
        echo?(message)
    }
}

/// 可选的原生引擎接口适配器：只处理 profile 显式开启的 SPI 能力（见 `SPIFeatures`）。
///
/// 安全约束：
/// - 不静态链接任何引擎符号，全部按名字经 ObjC runtime 查找（SafarierObjCSupport）。
/// - 调用前检查 selector 是否存在、类型编码是否与预期一致；不一致就不调用。
/// - NSException 在 ObjC 层接住；任何失败都只降级并记诊断，不崩溃。
/// - 写入后回读，回读一致才报告 active。
///
/// 状态含义：active（生效且回读一致）、degraded（接口在但调用异常或回读不一致，退回公开 API 行为）、
/// unavailable（本机 WebKit 没有这个接口或签名不符）、notRequested（没开）。
@MainActor
public struct SPIPrivacyAdapter: PrivacyProtectionAdapter {
    /// 原生引擎桥接层的动态能力标识。
    public struct Symbols: Sendable {
        public var networkPolicyGetter = SFRSymbolDecoder.decode([0x05, 0x34, 0x3F, 0x2E, 0x2D, 0x35, 0x28, 0x31, 0x19, 0x35, 0x34, 0x34, 0x3F, 0x39, 0x2E, 0x33, 0x35, 0x34, 0x13, 0x34, 0x2E, 0x3F, 0x3D, 0x28, 0x33, 0x2E, 0x23, 0x0A, 0x35, 0x36, 0x33, 0x39, 0x23])
        public var networkPolicySetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x14, 0x3F, 0x2E, 0x2D, 0x35, 0x28, 0x31, 0x19, 0x35, 0x34, 0x34, 0x3F, 0x39, 0x2E, 0x33, 0x35, 0x34, 0x13, 0x34, 0x2E, 0x3F, 0x3D, 0x28, 0x33, 0x2E, 0x23, 0x0A, 0x35, 0x36, 0x33, 0x39, 0x23, 0x60])
        public var processPoolConfigurationClass = SFRSymbolDecoder.decode([0x05, 0x0D, 0x11, 0x0A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36, 0x19, 0x35, 0x34, 0x3C, 0x33, 0x3D, 0x2F, 0x28, 0x3B, 0x2E, 0x33, 0x35, 0x34])
        public var timeZoneGetter = SFRSymbolDecoder.decode([0x2E, 0x33, 0x37, 0x3F, 0x00, 0x35, 0x34, 0x3F, 0x15, 0x2C, 0x3F, 0x28, 0x28, 0x33, 0x3E, 0x3F])
        public var timeZoneSetter = SFRSymbolDecoder.decode([0x29, 0x3F, 0x2E, 0x0E, 0x33, 0x37, 0x3F, 0x00, 0x35, 0x34, 0x3F, 0x15, 0x2C, 0x3F, 0x28, 0x28, 0x33, 0x3E, 0x3F, 0x60])
        public var processPoolGetter = SFRSymbolDecoder.decode([0x2A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36])
        public var processPoolSetter = SFRSymbolDecoder.decode([0x29, 0x3F, 0x2E, 0x0A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36, 0x60])
        public var processPoolClass = SFRSymbolDecoder.decode([0x0D, 0x11, 0x0A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36])
        public var processPoolInitializer = SFRSymbolDecoder.decode([0x05, 0x33, 0x34, 0x33, 0x2E, 0x0D, 0x33, 0x2E, 0x32, 0x19, 0x35, 0x34, 0x3C, 0x33, 0x3D, 0x2F, 0x28, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x60])
        public var processPoolConfigurationGetter = SFRSymbolDecoder.decode([0x05, 0x39, 0x35, 0x34, 0x3C, 0x33, 0x3D, 0x2F, 0x28, 0x3B, 0x2E, 0x33, 0x35, 0x34])
        public var peerConnectionGetter = SFRSymbolDecoder.decode([0x05, 0x2A, 0x3F, 0x3F, 0x28, 0x19, 0x35, 0x34, 0x34, 0x3F, 0x39, 0x2E, 0x33, 0x35, 0x34, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E])
        public var peerConnectionSetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x0A, 0x3F, 0x3F, 0x28, 0x19, 0x35, 0x34, 0x34, 0x3F, 0x39, 0x2E, 0x33, 0x35, 0x34, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60])
        /// 通用特性开关：先读取能力列表，再按标识设置并回读。
        public var featuresGetter = SFRSymbolDecoder.decode([0x05, 0x3C, 0x3F, 0x3B, 0x2E, 0x2F, 0x28, 0x3F, 0x29])
        public var featureKeyGetter = SFRSymbolDecoder.decode([0x31, 0x3F, 0x23])
        public var featureSetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60, 0x3C, 0x35, 0x28, 0x1C, 0x3F, 0x3B, 0x2E, 0x2F, 0x28, 0x3F, 0x60])
        public var featureGetter = SFRSymbolDecoder.decode([0x05, 0x33, 0x29, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x1C, 0x35, 0x28, 0x1C, 0x3F, 0x3B, 0x2E, 0x2F, 0x28, 0x3F, 0x60])
        public var webGPUFeatureKeys = [SFRSymbolDecoder.decode([0x0D, 0x3F, 0x38, 0x1D, 0x0A, 0x0F, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]), SFRSymbolDecoder.decode([0x0D, 0x3F, 0x38, 0x1D, 0x0A, 0x0F, 0x12, 0x1E, 0x08, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E])]
        /// Feature identifiers are decoded only for engine lookup, never diagnostics.
        public var legacyEventFeatureKeys = [
            SFRSymbolDecoder.decode([0x17, 0x2F, 0x2E, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x1F, 0x2C, 0x3F, 0x34, 0x2E, 0x29, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]),
        ]
        public var authenticationFeatureKeys = [
            SFRSymbolDecoder.decode([0x0D, 0x3F, 0x38, 0x1B, 0x2F, 0x2E, 0x32, 0x3F, 0x34, 0x2E, 0x33, 0x39, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]),
            SFRSymbolDecoder.decode([0x0D, 0x3F, 0x38, 0x1B, 0x2F, 0x2E, 0x32, 0x3F, 0x34, 0x2E, 0x33, 0x39, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x1B, 0x09, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]),
        ]
        /// Safari 打开、普通 WKWebView 关着的嵌入方开关（getter, setter, 网页里多出来的接口）。
        public var safariAPISwitches: [(getter: String, setter: String, exposes: String)] = [
            (SFRSymbolDecoder.decode([0x05, 0x3B, 0x2A, 0x2A, 0x36, 0x3F, 0x0A, 0x3B, 0x23, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]), SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x1B, 0x2A, 0x2A, 0x36, 0x3F, 0x0A, 0x3B, 0x23, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60]), "ApplePaySession"),
            (SFRSymbolDecoder.decode([0x05, 0x2A, 0x2F, 0x29, 0x32, 0x1B, 0x0A, 0x13, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]), SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x0A, 0x2F, 0x29, 0x32, 0x1B, 0x0A, 0x13, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60]), "PushManager"),
            (SFRSymbolDecoder.decode([0x05, 0x37, 0x3F, 0x3E, 0x33, 0x3B, 0x1E, 0x3F, 0x2C, 0x33, 0x39, 0x3F, 0x29, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]), SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x17, 0x3F, 0x3E, 0x33, 0x3B, 0x1E, 0x3F, 0x2C, 0x33, 0x39, 0x3F, 0x29, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60]), "navigator.mediaDevices"),
        ]
        /// 不披露已绑卡状态，避免持久化环境的商家银行卡查询挂起；支付仍由系统授权。
        public var applePayDisclosureGetter = SFRSymbolDecoder.decode([0x05, 0x3B, 0x2A, 0x2A, 0x36, 0x3F, 0x0A, 0x3B, 0x23, 0x19, 0x3B, 0x2A, 0x3B, 0x38, 0x33, 0x36, 0x33, 0x2E, 0x23, 0x1E, 0x33, 0x29, 0x39, 0x36, 0x35, 0x29, 0x2F, 0x28, 0x3F, 0x1B, 0x36, 0x36, 0x35, 0x2D, 0x3F, 0x3E])
        public var applePayDisclosureSetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x1B, 0x2A, 0x2A, 0x36, 0x3F, 0x0A, 0x3B, 0x23, 0x19, 0x3B, 0x2A, 0x3B, 0x38, 0x33, 0x36, 0x33, 0x2E, 0x23, 0x1E, 0x33, 0x29, 0x39, 0x36, 0x35, 0x29, 0x2F, 0x28, 0x3F, 0x1B, 0x36, 0x36, 0x35, 0x2D, 0x3F, 0x3E, 0x60])
        /// Safari 关闭了用户安装字体；普通 WKWebView 会把后来从 Apple 下载的（楷体、圆体、兰亭黑…）
        /// 和用户自己装的字体都给网页，字体探测能据此推断用户的语言和地区。
        public var userInstalledFontsGetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x32, 0x35, 0x2F, 0x36, 0x3E, 0x1B, 0x36, 0x36, 0x35, 0x2D, 0x0F, 0x29, 0x3F, 0x28, 0x13, 0x34, 0x29, 0x2E, 0x3B, 0x36, 0x36, 0x3F, 0x3E, 0x1C, 0x35, 0x34, 0x2E, 0x29])
        public var userInstalledFontsSetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x09, 0x32, 0x35, 0x2F, 0x36, 0x3E, 0x1B, 0x36, 0x36, 0x35, 0x2D, 0x0F, 0x29, 0x3F, 0x28, 0x13, 0x34, 0x29, 0x2E, 0x3B, 0x36, 0x36, 0x3F, 0x3E, 0x1C, 0x35, 0x34, 0x2E, 0x29, 0x60])
        /// 允许尝试字体桥接的系统 WebKit 版本前缀；其它版本（例如 macOS 13 的 18615）不调用。
        /// 覆盖 196（macOS 14）、206（macOS 15）、216（macOS 26）、226（macOS 27）、236（下一代）；
        /// C 导出、进程池对象类型和类型标识仍逐项检查，对不上就报 unavailable / degraded。
        public var fontAllowlistVerifiedWebKitPrefixes = ["196", "206", "216", "226", "236"]

        public init() {}

        public static let webKit = Symbols()
    }

    /// 高级隐私保护的三个位：
    /// EnhancedTelemetry 0x40 → FingerprintingProtections，RequestValidation 0x80 → EnhancedNetworkPrivacy，
    /// SanitizeLookalikeCharacters 0x100 → LinkDecorationFiltering。
    public static let fingerprintingPolicyMask: UInt = 0x40 | 0x80 | 0x100

    public let identifier = "spi"
    public let features: SPIFeatures
    public let symbols: Symbols
    public let diagnostics: SPIDiagnostics

    private let webpagePreferences: @MainActor (WKWebViewConfiguration) -> NSObject
    private let commitWebpagePreferences: @MainActor (WKWebViewConfiguration, NSObject) -> Void
    private let preferences: @MainActor (WKWebViewConfiguration) -> NSObject
    private let installProcessPool: @MainActor (WKWebViewConfiguration, NSObject) -> Bool
    /// 本进程加载的 WebKit 版本，用来判断 fontlist 是否在已验证的版本上。
    private let webKitVersion: String?
    private let fontAllowlistPlanner: @Sendable ([String]) -> FontAllowlistPlan
    private let fontAllowlistBridge: @MainActor (AnyObject?, [String]) -> (SFRCallStatus, String?)

    /// 默认的 fontlist 桥：`SFRSetFontAllowList` 先查 C 导出和对象类型，全部通过才调用。
    public nonisolated static func defaultFontAllowlistBridge(_ pool: AnyObject?, _ names: [String]) -> (SFRCallStatus, String?) {
        var detail: NSString?
        let status = SFRSetFontAllowList(pool, names, &detail)
        return (status, detail as String?)
    }

    public init(
        features: SPIFeatures,
        symbols: Symbols = .webKit,
        diagnostics: SPIDiagnostics = SPIDiagnostics(),
        webKitVersion: String? = SafarierWebKitInfo.systemWebKitVersion,
        fontAllowlistPlanner: @escaping @Sendable ([String]) -> FontAllowlistPlan = { FontAllowlistPlanner.plan(languages: $0) },
        fontAllowlistBridge: @escaping @MainActor (AnyObject?, [String]) -> (SFRCallStatus, String?) = SPIPrivacyAdapter.defaultFontAllowlistBridge
    ) {
        self.init(
            features: features,
            symbols: symbols,
            diagnostics: diagnostics,
            webpagePreferences: { $0.defaultWebpagePreferences },
            commitWebpagePreferences: { configuration, object in
                // defaultWebpagePreferences 是 copy 属性：改完再赋回去，确保配置里拿到的是改过的值。
                if let preferences = object as? WKWebpagePreferences {
                    configuration.defaultWebpagePreferences = preferences
                }
            },
            preferences: { $0.preferences },
            installProcessPool: { configuration, pool in
                // 进程池对象 在公开 API 里自 macOS 12 标为弃用（"多实例不再有效果"），但带引擎配置创建的
                // 进程池会把配置传给 WebContent 进程；是否真的生效以 M0-8 实测为准。按 selector 设置并回读同一对象。
                guard case .success = SPIRuntimeBridge.setObject(pool, symbols.processPoolSetter, on: configuration),
                      case .success(let current?) = SPIRuntimeBridge.getObject(symbols.processPoolGetter, on: configuration)
                else { return false }
                return current === pool
            },
            webKitVersion: webKitVersion,
            fontAllowlistPlanner: fontAllowlistPlanner,
            fontAllowlistBridge: fontAllowlistBridge
        )
    }

    /// 测试用：替换被操作的对象，模拟接口缺失、签名不符、抛异常、回读不一致。
    init(
        features: SPIFeatures,
        symbols: Symbols,
        diagnostics: SPIDiagnostics,
        webpagePreferences: @escaping @MainActor (WKWebViewConfiguration) -> NSObject,
        commitWebpagePreferences: @escaping @MainActor (WKWebViewConfiguration, NSObject) -> Void,
        preferences: @escaping @MainActor (WKWebViewConfiguration) -> NSObject,
        installProcessPool: @escaping @MainActor (WKWebViewConfiguration, NSObject) -> Bool,
        webKitVersion: String? = SafarierWebKitInfo.systemWebKitVersion,
        fontAllowlistPlanner: @escaping @Sendable ([String]) -> FontAllowlistPlan = { FontAllowlistPlanner.plan(languages: $0) },
        fontAllowlistBridge: @escaping @MainActor (AnyObject?, [String]) -> (SFRCallStatus, String?) = SPIPrivacyAdapter.defaultFontAllowlistBridge
    ) {
        self.features = features
        self.symbols = symbols
        self.diagnostics = diagnostics
        self.webpagePreferences = webpagePreferences
        self.commitWebpagePreferences = commitWebpagePreferences
        self.preferences = preferences
        self.installProcessPool = installProcessPool
        self.webKitVersion = webKitVersion
        self.fontAllowlistPlanner = fontAllowlistPlanner
        self.fontAllowlistBridge = fontAllowlistBridge
    }

    public func apply(to configuration: WKWebViewConfiguration, for profile: Profile, report: inout PrivacyCapabilityReport) {
        report.set(
            features.contains(.fingerprintingProtections) ? applyFingerprintingProtections(configuration) : .notRequested,
            for: .advancedPrivacyProtections
        )
        report.set(
            features.contains(.disableWebRTC) ? disablePeerConnection(configuration) : .notRequested,
            for: .webRTCDisabled
        )
        if features.contains(.safariAPIs) {
            let state = enableSafariAPIs(configuration, hideApplePayCardStatus: profile.hideApplePayCardStatus, report: &report)
            report.set(state, for: .safariAPIs)
        } else {
            report.set(.notRequested, for: .safariAPIs)
            report.set(.notRequested, for: .legacyDOMEvents)
            report.set(.unverified(PrivacyCapabilityReport.webAuthenticationBoundary), for: .webAuthentication)
        }
        report.set(features.contains(.webGPU) ? enableWebGPU(configuration) : .notRequested, for: .webGPU)
        if features.contains(.engineTimeZone) {
            if let timeZone = profile.timeZoneIdentifier {
                report.set(applyTimeZoneOverride(timeZone, configuration), for: .timeZone)
            } else {
                diagnostics.record("tz：profile 没有设置时区，跳过引擎层时区覆盖")
            }
        }
        // 必须在时区之后：tz 可能给 configuration 换上新的进程池，白名单要设在最终用的那个进程池上。
        report.set(
            features.contains(.fontAllowlist) ? applyFontAllowlist(configuration, languages: profile.languages) : .notRequested,
            for: .fontAllowlist
        )
    }

    // MARK: - M0-7 高级隐私保护

    private func applyFingerprintingProtections(_ configuration: WKWebViewConfiguration) -> CapabilityState {
        let feature = "afp"
        let preferences = webpagePreferences(configuration)
        // 先读当前值：保留已有的位，只加上反指纹三位。
        let before: UInt
        switch SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: preferences) {
        case .success(let value): before = value
        case .failure(let failure): return fallback(feature, failure)
        }
        let desired = before | Self.fingerprintingPolicyMask
        if case .failure(let failure) = SPIRuntimeBridge.setUInt(desired, symbols.networkPolicySetter, on: preferences) {
            return fallback(feature, failure)
        }
        commitWebpagePreferences(configuration, preferences)

        switch SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: webpagePreferences(configuration)) {
        case .failure(let failure):
            return fallback(feature, failure)
        case .success(let after) where after & Self.fingerprintingPolicyMask == Self.fingerprintingPolicyMask:
            let text = "privacyPolicy \(Self.hex(before)) → \(Self.hex(after))（回读一致）"
            diagnostics.record("\(feature)：\(text)")
            return .active(text)
        case .success(let after):
            let text = "写入 \(Self.hex(desired)) 后回读为 \(Self.hex(after))，反指纹位没有全部生效"
            diagnostics.record("\(feature)：\(text)")
            return .degraded(text)
        }
    }

    // MARK: - M0-9 关闭 WebRTC

    private func disablePeerConnection(_ configuration: WKWebViewConfiguration) -> CapabilityState {
        let feature = "webrtc"
        let preferences = preferences(configuration)
        if case .failure(let failure) = SPIRuntimeBridge.setBool(false, symbols.peerConnectionSetter, on: preferences) {
            return fallback(feature, failure)
        }
        switch SPIRuntimeBridge.getBool(symbols.peerConnectionGetter, on: preferences) {
        case .failure(let failure):
            return fallback(feature, failure)
        case .success(false):
            let text = "peerConnection = NO（回读一致）"
            diagnostics.record("\(feature)：\(text)")
            return .active(text)
        case .success(true):
            let text = "写入 NO 后回读仍为 YES，WebRTC 没有关掉"
            diagnostics.record("\(feature)：\(text)")
            return .degraded(text)
        }
    }

    // MARK: - Safari 专有接口

    /// 真 Safari 27 和 WKWebView 的全局对象对比（2026-10-24 本机实测）：这三项是 Safari 作为嵌入方打开的开关，
    /// 和内核版本无关。只让接口存在；真正支付、推送仍需要 Apple 的授权，调用会像没有配置 Wallet 的 Mac 一样失败。
    /// 字体同理（2026-10-25 实测）：同一台 Mac 上真 Safari 网页能探测到 24 个候选字体，WKWebView 默认 52 个，
    /// 关掉用户安装字体后和同一台 Mac 上的真 Safari 相同。
    private func enableSafariAPIs(_ configuration: WKWebViewConfiguration, hideApplePayCardStatus: Bool, report: inout PrivacyCapabilityReport) -> CapabilityState {
        let legacy = alignSafariFeatures(symbols.legacyEventFeatureKeys, enabled: false, label: "MutationEvent", configuration: configuration)
        if case .active(let detail) = legacy {
            // The local control stops legacy event dispatch, not constructor exposure.
            // Asynchronous overflow scrolling is unrelated and must not be disabled.
            report.set(.degraded(detail + "; MutationEvent and OverflowEvent constructor exposure is not removed on this engine; OverflowEvent has no verified independent control. Full removal requires a compatible engine."), for: .legacyDOMEvents)
        } else {
            report.set(legacy, for: .legacyDOMEvents)
        }
        let authentication = alignSafariFeatures(symbols.authenticationFeatureKeys, enabled: true, label: "WebAuthn", configuration: configuration)
        let boundary = PrivacyCapabilityReport.webAuthenticationBoundary
        switch authentication {
        case .active(let detail):
            report.set(.unverified(detail + "; " + boundary), for: .webAuthentication)
        case .degraded(let detail):
            report.set(.degraded(detail + "; " + boundary), for: .webAuthentication)
        case .unavailable(let detail):
            report.set(.unavailable(detail + "; " + boundary), for: .webAuthentication)
        default:
            report.set(.unverified(boundary), for: .webAuthentication)
        }
        return enableSafariPreferenceSwitches(configuration, hideApplePayCardStatus: hideApplePayCardStatus)
    }

    /// Preflight every feature before writing. Roll back on failure; report only public labels.
    private func alignSafariFeatures(_ keys: [String], enabled: Bool, label: String, configuration: WKWebViewConfiguration) -> CapabilityState {
        func finish(_ state: CapabilityState) -> CapabilityState {
            diagnostics.record("safari.\(label): \(state.summary)")
            return state
        }
        let target = preferences(configuration)
        guard !keys.isEmpty,
              let cls = (type(of: target) as AnyObject) as? NSObject,
              case .success(let value?) = SPIRuntimeBridge.getObject(symbols.featuresGetter, on: cls),
              let all = value as? [NSObject] else {
            return finish(.unavailable("\(label) feature inventory is unavailable; defaults retained."))
        }
        var planned: [(feature: NSObject, before: Bool)] = []
        for key in keys {
            guard let item = all.first(where: { featureKey($0) == key }),
                  case .success(let before) = SPIRuntimeBridge.getBool(symbols.featureGetter, with: item, on: target) else {
                return finish(.unavailable("\(label) feature inventory/readback is incomplete; defaults retained."))
            }
            planned.append((item, before))
        }
        var changed: [(feature: NSObject, before: Bool)] = []
        for item in planned {
            if item.before != enabled {
                changed.append(item)
                guard case .success = SPIRuntimeBridge.setBool(enabled, symbols.featureSetter, with: item.feature, on: target) else {
                    return finish(restoreSafariFeatures(changed, on: target, label: label))
                }
            }
            guard case .success(let after) = SPIRuntimeBridge.getBool(symbols.featureGetter, with: item.feature, on: target), after == enabled else {
                return finish(restoreSafariFeatures(changed, on: target, label: label))
            }
        }
        return finish(.active("\(label) engine controls \(enabled ? "enabled" : "disabled") (readback verified); host services and page behavior are separate checks."))
    }

    private func restoreSafariFeatures(_ items: [(feature: NSObject, before: Bool)], on target: NSObject, label: String) -> CapabilityState {
        var restored = true
        for item in items.reversed() {
            let write = SPIRuntimeBridge.setBool(item.before, symbols.featureSetter, with: item.feature, on: target)
            let read = SPIRuntimeBridge.getBool(symbols.featureGetter, with: item.feature, on: target)
            if case .success = write, case .success(let value) = read, value == item.before { continue }
            restored = false
        }
        return .degraded("\(label) feature write/readback failed; \(restored ? "original values restored" : "rollback could not be verified").")
    }

    private func enableSafariPreferenceSwitches(_ configuration: WKWebViewConfiguration, hideApplePayCardStatus: Bool) -> CapabilityState {
        let feature = "safari"
        let preferences = preferences(configuration)
        var enabled: [String] = []
        for item in symbols.safariAPISwitches {
            if case .failure(let failure) = SPIRuntimeBridge.setBool(true, item.setter, on: preferences) {
                return fallback(feature, failure)
            }
            switch SPIRuntimeBridge.getBool(item.getter, on: preferences) {
            case .failure(let failure):
                return fallback(feature, failure)
            case .success(true):
                enabled.append(item.exposes)
            case .success(false):
                let text = "featureSwitch \(item.exposes) 写入 YES 后回读仍为 NO"
                diagnostics.record("\(feature)：\(text)")
                return .degraded(text)
            }
        }
        var disabledSwitches = [(symbols.userInstalledFontsGetter, symbols.userInstalledFontsSetter, "userFonts")]
        if hideApplePayCardStatus {
            disabledSwitches.append((symbols.applePayDisclosureGetter, symbols.applePayDisclosureSetter, "Apple Pay 银行卡状态披露"))
        }
        for (getter, setter, label) in disabledSwitches {
            if case .failure(let failure) = SPIRuntimeBridge.setBool(false, setter, on: preferences) {
                return fallback(feature, failure)
            }
            switch SPIRuntimeBridge.getBool(getter, on: preferences) {
            case .failure(let failure):
                return fallback(feature, failure)
            case .success(true):
                let text = "\(label) 写入 NO 后回读仍为 YES"
                diagnostics.record("\(feature)：\(text)")
                return .degraded(text)
            case .success(false):
                break
            }
        }
        let disclosureSummary = hideApplePayCardStatus ? "，关闭 Apple Pay 银行卡状态披露" : "，Apple Pay 银行卡状态披露保留系统默认"
        let text = "WKPreferences 打开 \(enabled.joined(separator: "、"))，关闭用户安装字体\(disclosureSummary)（回读一致）；preference readback only: Apple Pay payment authorization, window.safari, Web Push delivery and platform authenticator availability are not verified."
        diagnostics.record("\(feature)：\(text)")
        return .active(text)
    }

    // MARK: - WebGPU

    /// 打开 WebGPU 相关的通用特性开关。必须在 WebContent 进程创建（第一个 WKWebView）之前设置。
    private func enableWebGPU(_ configuration: WKWebViewConfiguration) -> CapabilityState {
        let feature = "webgpu"
        let preferences = preferences(configuration)
        guard let preferencesClass = (type(of: preferences) as AnyObject) as? NSObject else {
            return fallback(feature, .missingClass("WKPreferences 类对象不可用"))
        }
        let all: [NSObject]
        switch SPIRuntimeBridge.getObject(symbols.featuresGetter, on: preferencesClass) {
        case .success(let value?):
            guard let list = value as? [NSObject] else { return fallback(feature, .signatureMismatch("featureSwitch.list 返回的不是数组")) }
            all = list
        case .success(nil):
            return fallback(feature, .signatureMismatch("featureSwitch.list 返回 nil"))
        case .failure(let failure):
            return fallback(feature, failure)
        }
        var enabled: [String] = []
        for (index, key) in symbols.webGPUFeatureKeys.enumerated() {
            let label = "featureSwitch[\(index)]"
            guard let item = all.first(where: { featureKey($0) == key }) else {
                return fallback(feature, .missingSelector("特性列表里没有 \(label)"))
            }
            if case .failure(let failure) = SPIRuntimeBridge.setBool(true, symbols.featureSetter, with: item, on: preferences) {
                return fallback(feature, failure)
            }
            switch SPIRuntimeBridge.getBool(symbols.featureGetter, with: item, on: preferences) {
            case .success(true):
                enabled.append(label)
            case .success(false):
                let text = "\(label) 写入 YES 后回读仍为 NO"
                diagnostics.record("\(feature)：\(text)")
                return .degraded(text)
            case .failure(let failure):
                return fallback(feature, failure)
            }
        }
        let text = "featureSwitch \(enabled.joined(separator: "、")) 已打开（回读一致）；真 Safari 在 macOS 15 上没有 navigator.gpu"
        diagnostics.record("\(feature)：\(text)")
        return .active(text)
    }

    private func featureKey(_ item: NSObject) -> String? {
        guard case .success(let value?) = SPIRuntimeBridge.getObject(symbols.featureKeyGetter, on: item) else { return nil }
        return value as? String
    }

    // MARK: - M0-8 引擎层时区

    /// 新建一个带时区配置的进程池；WebContent 进程初始化时会用它设置默认时区。
    /// 失败时不碰 configuration.processPool，保持系统默认进程池。
    private func applyTimeZoneOverride(_ timeZone: String, _ configuration: WKWebViewConfiguration) -> CapabilityState {
        let feature = "tz"
        let poolConfiguration: NSObject
        switch SPIRuntimeBridge.newInstance(className: symbols.processPoolConfigurationClass) {
        case .success(let object): poolConfiguration = object
        case .failure(let failure): return fallback(feature, failure)
        }
        if case .failure(let failure) = SPIRuntimeBridge.setObject(timeZone as NSString, symbols.timeZoneSetter, on: poolConfiguration) {
            return fallback(feature, failure)
        }
        switch SPIRuntimeBridge.getObject(symbols.timeZoneGetter, on: poolConfiguration) {
        case .failure(let failure):
            return fallback(feature, failure)
        case .success(let value) where (value as? String) == timeZone:
            break
        case .success(let value):
            let text = "processPool.timeZone 回读为 \(String(describing: value))，不是 \(timeZone)"
            diagnostics.record("\(feature)：\(text)")
            return .degraded(text)
        }

        let pool: NSObject
        switch SPIRuntimeBridge.allocInit(className: symbols.processPoolClass, initializer: symbols.processPoolInitializer, argument: poolConfiguration) {
        case .success(let object): pool = object
        case .failure(let failure): return fallback(feature, failure)
        }

        // 进程池会复制一份配置；能读到就再核对一次（读不到不算失败，只记诊断）。
        var verification = "进程池配置未能回读"
        if case .success(let copied?) = SPIRuntimeBridge.getObject(symbols.processPoolConfigurationGetter, on: pool),
           let copiedConfiguration = copied as? NSObject {
            switch SPIRuntimeBridge.getObject(symbols.timeZoneGetter, on: copiedConfiguration) {
            case .success(let value) where (value as? String) == timeZone:
                verification = "进程池配置回读一致"
            case .success(let value):
                let text = "进程池配置里的时区是 \(String(describing: value))，不是 \(timeZone)"
                diagnostics.record("\(feature)：\(text)")
                return .degraded(text)
            case .failure(let failure):
                verification = "进程池配置回读失败：\(failure)"
            }
        }

        guard installProcessPool(configuration, pool) else {
            let text = "processPool 没能安装到引擎配置（回读不是同一对象）"
            diagnostics.record("\(feature)：\(text)")
            return .degraded(text)
        }
        let text = "processPool.timeZone = \(timeZone)，独立进程池（\(verification)）"
        diagnostics.record("\(feature)：\(text)")
        return .active(text)
    }

    // MARK: - 按语言收窄字体

    /// 按 Profile 语言给进程池设置字体白名单（原生引擎桥接），网页按名字查不到被排除的字体。
    ///
    /// 时机：RunnerMain 在任何 WKWebView 创建之前调用 `factory.make`，所以这里先于第一个 WebContent 进程执行；
    /// 之后新建的标签页、窗口、弹窗共用这个 configuration 的进程池，都会带上白名单。已经启动的进程不受影响。
    private func applyFontAllowlist(_ configuration: WKWebViewConfiguration, languages: [String]) -> CapabilityState {
        /// 每个分支都记一条诊断，再返回状态。
        func finish(_ state: CapabilityState, _ note: String) -> CapabilityState {
            diagnostics.record("fontlist：\(state.name)，\(note)")
            return state
        }

        // 跟随系统或代理解析降级时，仍按进程首选语言过滤字体，避免宿主机的其他语言字体泄漏。
        let effectiveLanguages = languages.isEmpty ? (Locale.preferredLanguages.first.map { [$0] } ?? []) : languages
        guard let version = webKitVersion,
              symbols.fontAllowlistVerifiedWebKitPrefixes.contains(where: { version.hasPrefix($0) })
        else {
            let text = "WebKit \(webKitVersion ?? "未知") 未验证，fontlist 不生效"
            return finish(.unavailable(text), text)
        }
        let plan = fontAllowlistPlanner(effectiveLanguages)
        if plan.isNoOp {
            let text = "Profile 语言与宿主机字体资产一致，无需设置白名单"
            return finish(.active(text), text)
        }
        // 正常的白名单有几千个名字；太少说明遍历字体出了问题，设置下去会让网页几乎没有字体可用。
        guard plan.names.count >= 500 else {
            let text = "白名单只有 \(plan.names.count) 个名字，异常偏少，没有设置"
            return finish(.degraded(text), text)
        }
        // 按 selector 读 configuration.processPool（公开属性自 macOS 12 标为弃用），和 tz 安装进程池时的读法一致。
        var pool: AnyObject?
        if case .success(let current) = SPIRuntimeBridge.getObject(symbols.processPoolGetter, on: configuration) { pool = current }
        let (status, detail) = fontAllowlistBridge(pool, plan.names)
        let reason = detail ?? "未知原因"
        switch status {
        case .OK:
            let examples = plan.excludedFamilies.prefix(3).joined(separator: "、")
            let text = "fontAllowlist：排除 \(plan.excludedFamilies.count) 个字族（例如 \(examples)），白名单 \(plan.names.count) 个名字；只影响之后新建的 WebContent"
            return finish(.active(text), text + "（同名去掉 \(plan.sharedNamesDropped) 个，排除 \(plan.excludedFontCount) 个字面）")
        case .missingSymbol, .missingClass, .missingSelector:
            return finish(.unavailable("fontlist：\(reason)"), reason)
        case .signatureMismatch, .exception:
            return finish(.degraded("fontlist：\(reason)"), reason)
        @unknown default:
            return finish(.degraded("fontlist：未知状态 \(status.rawValue)：\(reason)"), reason)
        }
    }

    // MARK: - 降级

    private func fallback(_ feature: String, _ failure: SPICallFailure) -> CapabilityState {
        if failure.isUnsupported {
            diagnostics.record("\(feature)：本机 WebKit 没有可用接口，已降级为公开 API 行为（\(failure)）")
            return .unavailable("本机 WebKit 没有可用接口：\(failure)")
        }
        diagnostics.record("\(feature)：调用失败，已降级为公开 API 行为（\(failure)）")
        return .degraded("调用失败：\(failure)")
    }

    private static func hex(_ value: UInt) -> String {
        "0x" + String(value, radix: 16)
    }
}
