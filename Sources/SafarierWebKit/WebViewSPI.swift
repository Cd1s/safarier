import WebKit

/// 浏览窗口菜单用到的几个 WKWebView 原生引擎接口：文本缩放、网页检查器、页面原始源代码。
/// 和其它原生引擎接口一样按名字动态调用（先查 selector 和类型编码），本机 WebKit 没有时返回失败，不崩溃。
/// 这些都只作用于 UI 进程里的 WKWebView，网页读不到（2026-10-27 本机 WebKit 20621.3.11 核对过签名）。
@MainActor
public enum WebViewSPI {
    public static let textZoomGetter = SFRSymbolDecoder.decode([0x05, 0x2E, 0x3F, 0x22, 0x2E, 0x00, 0x35, 0x35, 0x37, 0x1C, 0x3B, 0x39, 0x2E, 0x35, 0x28])
    public static let textZoomSetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x0E, 0x3F, 0x22, 0x2E, 0x00, 0x35, 0x35, 0x37, 0x1C, 0x3B, 0x39, 0x2E, 0x35, 0x28, 0x60])
    public static let inspectorGetter = SFRSymbolDecoder.decode([0x05, 0x33, 0x34, 0x29, 0x2A, 0x3F, 0x39, 0x2E, 0x35, 0x28])
    public static let developerExtrasGetter = SFRSymbolDecoder.decode([0x05, 0x3E, 0x3F, 0x2C, 0x3F, 0x36, 0x35, 0x2A, 0x3F, 0x28, 0x1F, 0x22, 0x2E, 0x28, 0x3B, 0x29, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E])
    public static let developerExtrasSetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x1E, 0x3F, 0x2C, 0x3F, 0x36, 0x35, 0x2A, 0x3F, 0x28, 0x1F, 0x22, 0x2E, 0x28, 0x3B, 0x29, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60])
    public static let mainResourceData = SFRSymbolDecoder.decode([0x05, 0x3D, 0x3F, 0x2E, 0x17, 0x3B, 0x33, 0x34, 0x08, 0x3F, 0x29, 0x35, 0x2F, 0x28, 0x39, 0x3F, 0x1E, 0x3B, 0x2E, 0x3B, 0x0D, 0x33, 0x2E, 0x32, 0x19, 0x35, 0x37, 0x2A, 0x36, 0x3F, 0x2E, 0x33, 0x35, 0x34, 0x12, 0x3B, 0x34, 0x3E, 0x36, 0x3F, 0x28, 0x60])

    /// 网页检查器的无参动作。
    public enum InspectorAction: String, Sendable {
        /// 打开网页检查器（Web Inspector）。
        case show
        /// 打开检查器并切到控制台。
        case showConsole
        /// 关闭网页检查器（停靠的和独立窗口的都关）。
        case close
    }

    /// 文本缩放倍数（只放大文字，不改布局宽度）；接口不在时返回 nil。
    public static func textZoomFactor(of webView: WKWebView) -> Double? {
        try? SPIRuntimeBridge.getDouble(textZoomGetter, on: webView).get()
    }

    @discardableResult
    public static func setTextZoomFactor(_ value: Double, on webView: WKWebView) -> Bool {
        (try? SPIRuntimeBridge.setDouble(value, textZoomSetter, on: webView).get()) != nil
    }

    /// 本机引擎是否提供网页检查器（菜单项据此启用）。
    public static func hasInspector(_ webView: WKWebView) -> Bool {
        webView.responds(to: NSSelectorFromString(inspectorGetter))
    }

    public static func isDeveloperExtrasEnabled(on preferences: WKPreferences) -> Bool {
        (try? SPIRuntimeBridge.getBool(developerExtrasGetter, on: preferences).get()) ?? false
    }

    @discardableResult
    public static func setDeveloperExtrasEnabled(_ enabled: Bool, on preferences: WKPreferences) -> Bool {
        (try? SPIRuntimeBridge.setBool(enabled, developerExtrasSetter, on: preferences).get()) != nil
    }

    /// 网页检查器现在是否开着（停靠或独立窗口）。接口不在时当作没开。
    public static func isInspectorVisible(_ webView: WKWebView) -> Bool {
        guard case .success(let inspector) = inspectorObject(of: webView) else { return false }
        return (try? SPIRuntimeBridge.getBool("isVisible", on: inspector).get()) ?? false
    }

    /// 打开网页检查器或控制台，或者关掉它。打开前自动开启 developerExtrasEnabled，避免 WebInspectorUIProxy::show() 提前返回。
    @discardableResult
    public static func inspector(_ action: InspectorAction, on webView: WKWebView) -> Result<Void, SPICallFailure> {
        if action != .close { setDeveloperExtrasEnabled(true, on: webView.configuration.preferences) }
        switch inspectorObject(of: webView) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let inspector):
            return SPIRuntimeBridge.callVoid(action.rawValue, on: inspector)
        }
    }

    private static func inspectorObject(of webView: WKWebView) -> Result<NSObject, SPICallFailure> {
        switch SPIRuntimeBridge.getObject(inspectorGetter, on: webView) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let object):
            guard let inspector = object as? NSObject else { return .failure(.missingClass("inspector 返回 nil")) }
            return .success(inspector)
        }
    }

    /// 主框架的原始响应正文（和真 Safari「显示页面源代码」一样是服务器发来的原文，不是脚本改过的 DOM）。
    /// 接口不在时立刻返回失败，调用方可以退回读 DOM。
    @discardableResult
    public static func mainResourceData(of webView: WKWebView, completion: @escaping @MainActor @Sendable (Data?) -> Void) -> Result<Void, SPICallFailure> {
        SPIRuntimeBridge.callWithDataCompletion(mainResourceData, on: webView) { data, _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { completion(data) }
            } else {
                Task { @MainActor in completion(data) }
            }
        }
    }
}
