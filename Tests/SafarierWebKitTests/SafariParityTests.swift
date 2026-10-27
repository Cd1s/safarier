import XCTest
import WebKit
import SafarierCore
@testable import SafarierWebKit

/// UA 版本与内核对齐、Safari 默认设置、机型像素比。
final class SafariParityTests: XCTestCase {
    func testUserAgentUsesInstalledSafariWhenSafariSharesOurWebKit() {
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "21623.1.2", installedSafari: "27.0", safariStagedWebKit: nil)
        XCTAssertEqual(choice?.version, "27.0")
        XCTAssertEqual(choice?.matchesEngine, true)
    }

    /// macOS 15 + Safari 27：Safari 用 App Cryptex 里专用的 WebKit 20625，我们只能用系统的 20621.3（= Safari 26.2）。
    func testUserAgentFollowsLoadedEngineWhenSafariUsesStagedWebKit() {
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "20621.3.11.11.3", installedSafari: "27.0", safariStagedWebKit: "20625.1.29.18.28")
        XCTAssertEqual(choice?.version, "26.2")
        XCTAssertEqual(choice?.matchesEngine, true)
        XCTAssertTrue(choice?.note.contains("20625") == true)
    }

    func testUnknownEngineKeepsInstalledVersionButReportsMismatch() {
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "20999.1.1", installedSafari: "27.0", safariStagedWebKit: "21000.1.1")
        XCTAssertEqual(choice?.version, "27.0")
        XCTAssertEqual(choice?.matchesEngine, false)
        XCTAssertNil(SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "1", installedSafari: nil, safariStagedWebKit: nil))
    }

    @MainActor
    func testFactoryAppliesSafariDefaultsAndMarksDeviceModelPending() throws {
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/26.2 Safari/605.1.15",
                                                  userAgentVersion: .init(version: "26.2", matchesEngine: false, note: "x"))
        let profile = Profile(name: "p", mode: .ephemeral, deviceModel: MacDeviceModel.macBookAir13M2.id)
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])

        XCTAssertTrue(output.configuration.preferences.isElementFullscreenEnabled)
        XCTAssertEqual(output.configuration.mediaTypesRequiringUserActionForPlayback, .audio)
        XCTAssertTrue(output.configuration.upgradeKnownHostsToHTTPS)
        XCTAssertEqual(output.report[.deviceModel].name, "unverified")
        XCTAssertEqual(output.report[.safariUserAgent].name, "degraded", "UA 与内核对不上时要如实报告")
        XCTAssertEqual(try factory.make(profile: Profile(name: "q", mode: .ephemeral), proxy: nil, processLanguages: []).report[.deviceModel], .notRequested)
    }

    /// 真实 WKWebView：像素比覆盖接口存在时必须生效并回读一致。
    @MainActor
    func testDeviceSimulationSetsPixelRatioOnRealWebView() throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: WKWebViewConfiguration())
        let state = DeviceSimulation(model: .macBookPro16M3Max, diagnostics: SPIDiagnostics()).apply(to: webView)
        guard WKWebView.instancesRespond(to: NSSelectorFromString(DeviceSimulation.setter)) else {
            return XCTAssertEqual(state.name, "unavailable")
        }
        XCTAssertEqual(state.name, "active", state.summary)
        XCTAssertEqual(try SPIRuntimeBridge.getDouble(DeviceSimulation.getter, on: webView).get(), 2)
    }
}
