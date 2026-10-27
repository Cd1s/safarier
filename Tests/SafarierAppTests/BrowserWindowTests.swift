import XCTest
import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

/// 浏览窗口的结构性检查：多标签 / 多窗口的创建与释放、窗口尺寸回调、地址栏焦点。
@MainActor
final class BrowserWindowTests: XCTestCase {
    private var session: BrowserSession!

    override func setUp() async throws {
        _ = NSApplication.shared
        let profile = Profile(name: "test", mode: .ephemeral)
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/26.2 Safari/605.1.15")
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        session = BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics())
    }

    override func tearDown() async throws {
        for controller in session.openControllers { controller.window.close() }
        session = nil
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 快速连开连关标签：关掉的标签（控制器、窗口、WebView）都要被释放，不留在会话里。
    func testRapidNewAndCloseTabsReleasesEverything() {
        let first = session.openWindow(url: nil)
        weak var weakTab: BrowserWindowController?
        weak var weakWebView: WKWebView?
        autoreleasepool {
            var tabs: [BrowserWindowController] = []
            for _ in 0..<15 { tabs.append(session.openTab(in: first, url: nil)) }
            XCTAssertEqual(first.window.tabbedWindows?.count, 16)
            weakTab = tabs.last
            weakWebView = tabs.last?.webView
            for tab in tabs { tab.window.close() }
            tabs.removeAll()
        }
        spin()
        XCTAssertEqual(session.openControllers.count, 1)
        XCTAssertNil(weakTab, "关掉的标签控制器没有被释放（循环引用）")
        XCTAssertNil(weakWebView, "关掉的标签 WebView 没有被释放")
        XCTAssertTrue(first.window.tabbedWindows == nil || first.window.tabbedWindows?.count == 1)
    }

    func testClosingLastTabClosesWindowAndEmptiesSession() {
        let window = session.openWindow(url: nil)
        let tab = session.openTab(in: window, url: nil)
        tab.window.close()
        window.window.close()
        spin()
        XCTAssertTrue(session.openControllers.isEmpty)
    }

    /// 每个窗口和标签都要把真实窗口尺寸交给 WebKit，否则网页读到 outerWidth = outerHeight = 0。
    func testEveryTabReportsLiveWindowFrame() {
        let window = session.openWindow(url: nil, contentSize: NSSize(width: 900, height: 600))
        let tab = session.openTab(in: window, url: nil)
        for controller in [window, tab] {
            var reported: CGRect?
            controller.webViewGetWindowFrame(controller.webView) { reported = $0 }
            XCTAssertEqual(reported, controller.window.frame)
            XCTAssertGreaterThan(reported?.width ?? 0, 0)
        }
        // 改窗口大小后回调给的是新尺寸（不是创建时记下的值）。
        window.window.setContentSize(NSSize(width: 1000, height: 700))
        var resized: CGRect?
        window.webViewGetWindowFrame(window.webView) { resized = $0 }
        XCTAssertEqual(resized, window.window.frame)
        XCTAssertEqual(window.webView.uiDelegate as? BrowserWindowController, window)
        XCTAssertEqual(tab.webView.uiDelegate as? BrowserWindowController, tab)
    }

    /// 端到端：网页里读到的 outerWidth / outerHeight 就是窗口尺寸，outer − inner 是工具栏高度。
    func testPageSeesRealOuterSize() throws {
        let controller = session.openWindow(url: nil, contentSize: NSSize(width: 800, height: 500))
        let loaded = expectation(description: "loaded")
        controller.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://example.invalid/"))
        var result: [Double] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            controller.webView.evaluateJavaScript("[outerWidth, outerHeight, innerWidth, innerHeight]") { value, _ in
                result = (value as? [NSNumber])?.map(\.doubleValue) ?? []
                loaded.fulfill()
            }
        }
        wait(for: [loaded], timeout: 15)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.first, Double(controller.window.frame.width))
        XCTAssertEqual(result[1], Double(controller.window.frame.height))
        XCTAssertGreaterThan(result[1], result[3], "outerHeight 应当比 innerHeight 多出工具栏")
    }

    /// 地址栏获得焦点时显示完整网址并全选。
    func testAddressBarFocusSelectsWholeURL() {
        let bar = AddressBar(isPrivate: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        window.makeKeyAndOrderFront(nil)
        let url = URL(string: "https://www.example.com/path?q=1")!
        bar.update(url: url, isLoading: false, progress: 0, secure: true)
        bar.focus()
        spin()
        guard let editor = window.firstResponder as? NSTextView else { return XCTFail("焦点没有进地址栏：\(String(describing: window.firstResponder))") }
        XCTAssertEqual(editor.string, url.absoluteString)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (url.absoluteString as NSString).length))
        window.close()
    }
}
