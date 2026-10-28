import WebKit
import SafarierCore

/// 机型模拟里 WebView 级别的部分：devicePixelRatio。窗口（视口）尺寸由 Runner 的窗口负责。
///
/// 原生引擎桥接提供设备像素比覆盖：devicePixelRatio、CSS 分辨率媒体查询、
/// 图片的 srcset 选择都跟着变，不需要往页面注入脚本（2026-10-24 本机实测 1x 屏幕上设成 2 后 devicePixelRatio = 2）。
/// 和其它原生引擎接口一样按名字动态调用，失败只降级。
@MainActor
public struct DeviceSimulation {
    public static let setter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x15, 0x2C, 0x3F, 0x28, 0x28, 0x33, 0x3E, 0x3F, 0x1E, 0x3F, 0x2C, 0x33, 0x39, 0x3F, 0x09, 0x39, 0x3B, 0x36, 0x3F, 0x1C, 0x3B, 0x39, 0x2E, 0x35, 0x28, 0x60])
    public static let getter = SFRSymbolDecoder.decode([0x05, 0x35, 0x2C, 0x3F, 0x28, 0x28, 0x33, 0x3E, 0x3F, 0x1E, 0x3F, 0x2C, 0x33, 0x39, 0x3F, 0x09, 0x39, 0x3B, 0x36, 0x3F, 0x1C, 0x3B, 0x39, 0x2E, 0x35, 0x28])

    public let model: MacDeviceModel
    public let diagnostics: SPIDiagnostics

    public init(model: MacDeviceModel, diagnostics: SPIDiagnostics) {
        self.model = model
        self.diagnostics = diagnostics
    }

    /// 屏幕能力（进程级）：让 WebKit 收集到的 ScreenProperties 是这款机型显示器的样子——
    /// 分辨率与可用区域、P3 色域、XDR（HDR）。网页的 `screen` 尺寸（关闭高级隐私保护时）和
    /// `color-gamut` / `dynamic-range` 媒体查询由 WebKit 原生算出，不注入脚本。必须在第一个 WKWebView 创建前调用。
    /// 机型不支持的项按机型报（sRGB / SDR），不沿用宿主机：在 XDR 宿主机上选非 HDR 机型，网页读到的也是 SDR。
    /// 窗口布局（AppKit、主程序）仍然用宿主机的真实屏幕，见 `hostVisibleFrame`。
    public static func installDisplayOverride(for model: MacDeviceModel, diagnostics: SPIDiagnostics) -> CapabilityState {
        switch SPIRuntimeBridge.installDisplayOverride(
            p3: model.displayP3, hdr: model.displayHDR,
            maxHeadroom: model.maxEDRHeadroom, currentHeadroom: model.currentEDRHeadroom,
            screenWidth: Double(model.screenWidth), screenHeight: Double(model.screenHeight), availHeight: Double(model.availHeight)
        ) {
        case .success:
            let gamut = model.displayP3 ? "P3 色域" : "sRGB"
            let range = model.displayHDR ? "HDR（EDR 余量 \(Self.format(model.maxEDRHeadroom))）" : "SDR"
            let geometry = "屏幕 \(model.screenWidth)×\(model.screenHeight)（可用 \(model.availWidth)×\(model.availHeight)）"
            let text = "\(model.name)：\(geometry)、\(gamut)、\(range)（替换 NSScreen / AVPlayer 的屏幕查询，WebKit 原生算出 screen 与媒体查询）"
            diagnostics.record("display：\(text)")
            return .active(text)
        case .failure(let failure):
            diagnostics.record("display：安装失败（\(failure)），保持真实屏幕")
            return failure.isUnsupported ? .unavailable("本机没有对应接口：\(failure)") : .degraded("安装失败：\(failure)")
        }
    }

    public static func removeDisplayOverride() {
        SPIRuntimeBridge.removeDisplayOverride()
    }

    /// 宿主机主屏幕真实的可用区域：显示器模拟期间也不变，给窗口布局（初始窗口能放多大）用。
    public static var hostVisibleFrame: CGRect {
        SPIRuntimeBridge.hostVisibleFrame()
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    public func apply(to webView: WKWebView) -> CapabilityState {
        let scale = Double(model.scale)
        let viewport = "视口 \(model.viewportWidth)×\(model.viewportHeight)"
        // 宿主机窗口本身的 backingScaleFactor 已经等于目标像素比（例如 Retina 屏都是 2x）时，
        // 直接沿用窗口原生像素比，避免在已经入窗的 WKWebView 上额外启用自定义 scale 影响图层与点击坐标。
        if let windowScale = webView.window?.backingScaleFactor, windowScale == scale {
            let text = "\(model.name)：\(viewport)，devicePixelRatio \(model.scale)（与宿主机 Retina 像素比原生一致）"
            diagnostics.record("device：\(text)")
            return .active(text)
        }
        if case .failure(let failure) = SPIRuntimeBridge.setDouble(scale, Self.setter, on: webView) {
            diagnostics.record("device：设置像素比失败（\(failure)），保持屏幕本身的像素比")
            return failure.isUnsupported
                ? .unavailable("\(model.name)：\(viewport)；本机 WebKit 没有像素比覆盖接口（\(failure)）")
                : .degraded("\(model.name)：\(viewport)；像素比覆盖调用失败（\(failure)）")
        }
        switch SPIRuntimeBridge.getDouble(Self.getter, on: webView) {
        case .success(let value) where value == scale:
            let text = "\(model.name)：\(viewport)，devicePixelRatio \(model.scale)（回读一致）"
            diagnostics.record("device：\(text)")
            return .active(text)
        case .success(let value):
            let text = "\(model.name)：写入像素比 \(model.scale) 后回读为 \(value)"
            diagnostics.record("device：\(text)")
            return .degraded(text)
        case .failure(let failure):
            let text = "\(model.name)：\(viewport)，devicePixelRatio \(model.scale)（回读失败：\(failure)）"
            diagnostics.record("device：\(text)")
            return .unverified(text)
        }
    }
}
