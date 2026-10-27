import WebKit
import SafarierCore

/// 隐私开关的唯一接入点。正式代码只依赖这个协议；原生引擎接口（Safari 无痕的高级隐私保护、
/// 引擎层时区、关闭 WebRTC）只在可选的 `SPIPrivacyAdapter` 里，运行时探测、失败降级，绝不崩溃。
@MainActor
public protocol PrivacyProtectionAdapter {
    var identifier: String { get }
    /// 只修改 `configuration`，并把各项能力的真实状态写进 `report`。
    func apply(to configuration: WKWebViewConfiguration, for profile: Profile, report: inout PrivacyCapabilityReport)
}

/// 默认适配器：只用公开 API，不碰任何私有开关，如实报告做不到的项。
public struct PublicAPIPrivacyAdapter: PrivacyProtectionAdapter {
    public let identifier = "public-api"

    public init() {}

    public func apply(to configuration: WKWebViewConfiguration, for profile: Profile, report: inout PrivacyCapabilityReport) {
        report.set(.unavailable("公开 API 没有对应开关；可用 --spi afp 启用原生引擎桥接"), for: .advancedPrivacyProtections)
        report.set(.unavailable("公开 API 无法关闭 WebRTC；可用 --spi webrtc 启用原生引擎桥接"), for: .webRTCDisabled)
        report.set(.unavailable("普通 WKWebView 没有 ApplePaySession、PushManager、navigator.mediaDevices，网页还能看到后来下载和用户安装的字体；可用 --spi safari 打开"), for: .safariAPIs)
        report.set(.notRequested, for: .webGPU)
    }
}

/// 按顺序套用多个适配器；后面的适配器可以覆盖前面写下的结论。
public struct CompositePrivacyAdapter: PrivacyProtectionAdapter {
    public let adapters: [any PrivacyProtectionAdapter]

    public init(_ adapters: [any PrivacyProtectionAdapter]) {
        self.adapters = adapters
    }

    public var identifier: String {
        adapters.map(\.identifier).joined(separator: "+")
    }

    public func apply(to configuration: WKWebViewConfiguration, for profile: Profile, report: inout PrivacyCapabilityReport) {
        for adapter in adapters {
            adapter.apply(to: configuration, for: profile, report: &report)
        }
    }
}
