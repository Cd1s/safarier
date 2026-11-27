import XCTest
import AppKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

@MainActor
final class StartupBrowserTabsTests: XCTestCase {
    private var session: BrowserSession!
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("startup-browser-\(UUID())")
        let profile = Profile(name: "Startup", mode: .ephemeral, spi: [])
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore())
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        session = BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics(), workspace: SafarierWorkspace(root: root))
    }

    override func tearDown() async throws {
        session.stopAgentBridge()
        for controller in session.openControllers { controller.window.close() }
        session = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testStartupCreatesOrderedTabsInOneWindowAndSelectsFirst() throws {
        // 本地页面避免依赖外部网络，同时覆盖三个标签的排序和选中状态。
        let urls = (1...3).map { URL(string: "about:blank#\($0)")! }
        session.start(urls: urls, background: true)
        let controllers = session.openControllers
        XCTAssertEqual(controllers.count, 3)
        let first = try XCTUnwrap(controllers.first)
        let windows = try XCTUnwrap(first.window.tabbedWindows)
        XCTAssertEqual(windows, controllers.map(\.window))
        XCTAssertTrue(first.window.tabGroup?.selectedWindow === first.window)
        XCTAssertEqual(controllers.map(\.webView.url), urls)
    }

    func testEmptyStartupListOpensOneStartPage() throws {
        session.start(urls: [], background: true)
        XCTAssertEqual(session.openControllers.count, 1)
        XCTAssertTrue(try XCTUnwrap(session.openControllers.first).isBlankStartPage)
    }
}
