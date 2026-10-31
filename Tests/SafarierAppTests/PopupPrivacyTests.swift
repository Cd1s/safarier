import XCTest
import AppKit
import WebKit
import SafarierCore
@testable import SafarierWebKit
@testable import Safarier

/// 网页打开的弹窗（window.open / target=_blank）：WebKit 交来的配置原样用，window.opener 还在；
/// 建 WebView 前在它上面对齐页面级隐私设置（高级隐私保护 0x1c1 等），和打开它的网页共用同一个进程池和网站数据存储。
@MainActor
final class PopupPrivacyTests: XCTestCase {
    private var session: BrowserSession?

    override func tearDown() async throws {
        for controller in session?.openControllers ?? [] { controller.window.close() }
        session = nil
    }

    @discardableResult
    private func spin(_ timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, _ in result = value; done = true }
        spin { done }
        return result
    }

    private let processPoolGetter = SFRSymbolDecoder.decode([0x2A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36])

    func testWindowOpenKeepsOpenerAndAlignsAdvancedPrivacy() throws {
        _ = NSApplication.shared
        let profile = Profile(name: "popup", mode: .ephemeral, timeZoneIdentifier: "Asia/Tokyo")
        // 时区让会话用上自己的进程池：弹窗必须还在这个进程池里。字体白名单要遍历字体，这里不需要。
        let features: SPIFeatures = [.fingerprintingProtections, .engineTimeZone, .safariAPIs, .disableWebRTC]
        let privacy = CompositePrivacyAdapter([PublicAPIPrivacyAdapter(), SPIPrivacyAdapter(features: features)])
        let output = try WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), privacy: privacy)
            .make(profile: profile, proxy: nil, processLanguages: [])
        let session = BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics())
        self.session = session
        XCTAssertNil(session.lastPopupReport)

        let opener = session.openWindow(url: nil)
        opener.webView.loadHTMLString("<!doctype html><title>opener</title>", baseURL: URL(string: "https://opener.example.invalid/"))
        XCTAssertTrue(spin { opener.webView.url != nil && !opener.webView.isLoading })
        let opened = evaluate("(() => { const w = window.open('', '_blank'); return w !== null && w.opener === window; })()", in: opener.webView) as? Bool
        XCTAssertEqual(opened, true, "弹窗用 WebKit 交来的配置建，window.opener 指回打开它的网页")
        XCTAssertTrue(spin { session.openControllers.count == 2 })
        let popup = try XCTUnwrap(session.openControllers.first { $0 !== opener })
        XCTAssertTrue(popup.isPopup)

        let popupReport = try XCTUnwrap(session.lastPopupReport, "建弹窗 WebView 之前对齐过页面级设置")
        XCTAssertEqual(popupReport[.advancedPrivacyProtections].name, "active", popupReport[.advancedPrivacyProtections].summary)
        XCTAssertEqual(popupReport[.safariAPIs].name, session.report[.safariAPIs].name)
        XCTAssertEqual(popupReport[.webRTCDisabled].name, session.report[.webRTCDisabled].name)
        XCTAssertEqual(popupReport[.timeZone], .unavailable("未评估"), "时区在进程池上，弹窗不重设")

        let configuration = popup.webView.configuration
        let sessionPool = try SPIRuntimeBridge.getObject(processPoolGetter, on: session.configuration).get()
        XCTAssertTrue(try SPIRuntimeBridge.getObject(processPoolGetter, on: configuration).get() === sessionPool, "和打开它的网页同一个进程池")
        XCTAssertTrue(configuration.websiteDataStore === session.configuration.websiteDataStore, "同一个网站数据存储")

        let symbols = SPIPrivacyAdapter.Symbols.webKit
        if WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicySetter)) {
            let policy = try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: configuration.defaultWebpagePreferences).get()
            XCTAssertEqual(policy & 0x1C1, 0x1C1)
            if WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicyEnabledGetter)) {
                XCTAssertTrue(try SPIRuntimeBridge.getBool(symbols.networkPolicyEnabledGetter, on: configuration.defaultWebpagePreferences).get())
            }
        }

        XCTAssertEqual(evaluate("window.opener !== null", in: popup.webView) as? Bool, true, "弹窗里也能拿到 window.opener")
        let probe = "[typeof ApplePaySession, typeof RTCPeerConnection, Intl.DateTimeFormat().resolvedOptions().timeZone].join('|')"
        let openerSees = try XCTUnwrap(evaluate(probe, in: opener.webView) as? String)
        XCTAssertEqual(evaluate(probe, in: popup.webView) as? String, openerSees, "弹窗和打开它的网页看到的 Safari 接口、WebRTC、时区一致")
        XCTAssertTrue(openerSees.hasSuffix("|Asia/Tokyo"), openerSees)
    }
}
