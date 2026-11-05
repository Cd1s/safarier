import XCTest
import AppKit
import WebKit
import SafarierCore
@testable import SafarierWebKit
@testable import Safarier

/// 4 参数导航决策回调：放行的每次导航，都在 WebKit 交来的单次导航 WKWebpagePreferences 上确保高级隐私保护位（和 Safari 的导航代理一样）。
@MainActor
final class NavigationPreferencesTests: XCTestCase {
    /// 放在 SPI 适配器前面：把单次导航的位清零，模拟 WebKit 交来没对齐的 preferences。
    private final class ClearingAdapter: PrivacyProtectionAdapter {
        let identifier = "clear"
        func apply(to configuration: WKWebViewConfiguration, for profile: Profile, report: inout PrivacyCapabilityReport) {}
        func alignNavigationPreferences(_ preferences: WKWebpagePreferences) {
            _ = SPIRuntimeBridge.setUInt(0, SPIPrivacyAdapter.Symbols.webKit.networkPolicySetter, on: preferences)
        }
    }

    /// 放在 SPI 适配器后面：记下对齐之后的值。
    private final class RecordingAdapter: PrivacyProtectionAdapter {
        let identifier = "record"
        var seen: [(policy: UInt, enabled: Bool?)] = []
        func apply(to configuration: WKWebViewConfiguration, for profile: Profile, report: inout PrivacyCapabilityReport) {}
        func alignNavigationPreferences(_ preferences: WKWebpagePreferences) {
            let symbols = SPIPrivacyAdapter.Symbols.webKit
            let policy = (try? SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: preferences).get()) ?? 0
            seen.append((policy, try? SPIRuntimeBridge.getBool(symbols.networkPolicyEnabledGetter, on: preferences).get()))
        }
    }

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

    func testEveryAllowedNavigationGetsAdvancedPrivacyBits() throws {
        _ = NSApplication.shared
        let symbols = SPIPrivacyAdapter.Symbols.webKit
        guard WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicySetter)) else {
            throw XCTSkip("本机 WebKit 没有高级隐私保护位接口")
        }
        let recorder = RecordingAdapter()
        let profile = Profile(name: "navigation", mode: .ephemeral)
        let privacy = CompositePrivacyAdapter([
            PublicAPIPrivacyAdapter(), ClearingAdapter(), SPIPrivacyAdapter(features: .fingerprintingProtections), recorder,
        ])
        let output = try WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), privacy: privacy)
            .make(profile: profile, proxy: nil, processLanguages: [])
        let session = BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics())
        self.session = session

        // 两次导航都由本机服务响应，隐私位检查不依赖 .invalid 域名的网络失败何时返回。
        let server = try LoopbackHTTPServer(routes: [
            "/first": .init(status: 200, headers: ["Content-Type": "text/html"],
                            body: "<!doctype html><title>First</title><a id=next href='/second'>next</a>"),
            "/second": .init(status: 200, headers: ["Content-Type": "text/html"],
                             body: "<!doctype html><title>Second</title><p>second</p>"),
        ])
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        let port = try XCTUnwrap(server.port)
        let first = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/first"))
        let second = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/second"))
        let controller = session.openWindow(url: first)
        XCTAssertTrue(spin {
            controller.webView.url == first && controller.webView.title == "First" && !controller.webView.isLoading
        })
        XCTAssertGreaterThanOrEqual(recorder.seen.count, 1, "载入网页走了 4 参数回调")

        // 网页里点链接：再完成一次放行的导航，并核验它独立的 preferences。
        let before = recorder.seen.count
        controller.webView.evaluateJavaScript("document.getElementById('next').click()") { _, error in
            XCTAssertNil(error)
        }
        XCTAssertTrue(spin(15) {
            recorder.seen.count > before && controller.webView.url == second
                && controller.webView.title == "Second" && !controller.webView.isLoading
        })
        XCTAssertNil(controller.failedURL)

        for (index, entry) in recorder.seen.enumerated() {
            XCTAssertEqual(entry.policy & 0x1C1, 0x1C1, "第 \(index + 1) 次导航")
            if let enabled = entry.enabled { XCTAssertTrue(enabled, "第 \(index + 1) 次导航的总开关") }
        }
    }
}
