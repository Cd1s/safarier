import Foundation

/// Runner 关心的隐私与一致性能力。每一项都要说明落实方式，或者为什么没落实。
public enum PrivacyFeature: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    /// Safari 无痕同款的高级隐私保护（含反指纹噪声）。目前没有公开 API，等 M0 验证原生引擎接口。
    case advancedPrivacyProtections
    /// 每个 profile 独立的网站数据（Cookie、存储、缓存、HSTS）。
    case dataIsolation
    /// 按 profile 走代理。
    case proxy
    /// 引擎看到的时区。
    case timeZone
    /// navigator.languages / Accept-Language。
    case languages
    /// 关闭 WebRTC，避免绕过代理暴露真实 IP。
    case webRTCDisabled
    /// UA 与本机 Safari 一致（WKWebView 默认 UA 缺少 `Version/x Safari/605.1.15`），且版本与实际加载的 WebKit 对应。
    case safariUserAgent
    /// Safari 才有的网页接口（Apple Pay、Push、媒体设备）。
    case safariAPIs
    /// 模拟机型：视口尺寸和 devicePixelRatio。
    case deviceModel
    /// 模拟机型的屏幕：P3 色域、HDR（媒体查询 color-gamut / dynamic-range）。
    case displayCapabilities
    /// WebGPU（navigator.gpu）。
    case webGPU
    /// 按 Profile 语言收窄网页能按名字用的字体（原生引擎桥接 白名单），
    /// 让英文、泰语等环境的网页查不到宿主机按中日韩语言下载的字体资产。只影响之后新建的 WebContent 进程。
    case fontAllowlist
}

public enum CapabilityState: Equatable, Codable, Sendable {
    /// 已生效（设置后回读一致），参数说明落实方式。
    case active(String)
    /// 请求了，接口也在，但调用异常或回读不一致，已退回公开 API 行为；参数说明原因。
    case degraded(String)
    /// 已经设置，但还没验证网页里是否真的生效（M0 待测）。
    case unverified(String)
    /// profile 没有要求这一项（例如没配代理、没开对应的 SPI）。
    case notRequested
    /// 做不到（公开 API 没有、或本机 WebKit 没有对应原生引擎接口），参数说明原因。
    case unavailable(String)

    /// 机器可读的状态名：active / degraded / unverified / notRequested / unavailable。
    public var name: String {
        switch self {
        case .active: return "active"
        case .degraded: return "degraded"
        case .unverified: return "unverified"
        case .notRequested: return "notRequested"
        case .unavailable: return "unavailable"
        }
    }

    public var detail: String? {
        switch self {
        case .active(let text), .degraded(let text), .unverified(let text), .unavailable(let text): return text
        case .notRequested: return nil
        }
    }

    public var summary: String {
        detail.map { "\(name) — \($0)" } ?? name
    }
}

public struct PrivacyCapabilityReport: Equatable, Codable, Sendable {
    public private(set) var states: [PrivacyFeature: CapabilityState]

    public init(states: [PrivacyFeature: CapabilityState] = [:]) {
        self.states = states
    }

    public subscript(feature: PrivacyFeature) -> CapabilityState {
        states[feature] ?? .unavailable("未评估")
    }

    public mutating func set(_ state: CapabilityState, for feature: PrivacyFeature) {
        states[feature] = state
    }

    /// 按 `PrivacyFeature.allCases` 的顺序输出，便于日志和回归对比。
    public func lines() -> [String] {
        PrivacyFeature.allCases.map { "\($0.rawValue): \(self[$0].summary)" }
    }
}
