import XCTest
import AppKit
import Network
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

/// Round 3 浏览窗口修复：网页打开的视图不抢地址栏、target=_blank 走 createWebViewWith、源代码窗口、标签选中、
/// 出错页网址残留、⇧⌘H 历史、右键打开方式的定时器、菜单置灰、地址栏 Esc。
@MainActor
final class BrowserFixesTests: XCTestCase {
    private var session: BrowserSession!

    override func setUp() async throws {
        _ = NSApplication.shared
        session = try Self.makeSession(Profile(name: "fix", mode: .ephemeral))
    }

    override func tearDown() async throws {
        for controller in session.openControllers { controller.window.close() }
        session = nil
    }

    static func makeSession(_ profile: Profile) throws -> BrowserSession {
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "20621.3.11.11.3", installedSafari: "27.0", safariStagedWebKit: "20625.1.29.18.28")
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), userAgentVersion: choice)
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        return BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics())
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 等到条件成立（最多 `timeout` 秒）。
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { spin(0.1) }
    }

    // MARK: - 网页打开的视图

    /// window.open / target=_blank / 右键新标签：不走起始页、不抢地址栏焦点，前台打开时焦点在网页上。
    func testPopupTabDoesNotShowStartPageOrGrabAddressBar() {
        let host = session.openWindow(url: nil)
        let popup = session.openTab(in: host, url: nil, configuration: session.configuration, background: false)
        spin()
        XCTAssertTrue(popup.isPopup)
        XCTAssertFalse(popup.isShowingStartPage, "空白弹窗不能被起始页盖住")
        XCTAssertFalse(popup.wantsAddressFocus)
        XCTAssertFalse(popup.window.firstResponder is NSTextView, "地址栏没有进入编辑状态")
        XCTAssertTrue(popup.window.firstResponder === popup.webView || (popup.window.firstResponder as? NSView)?.isDescendant(of: popup.webView) == true)

        let background = session.openTab(in: host, url: nil, configuration: session.configuration, background: true)
        XCTAssertFalse(background.wantsAddressFocus, "后台标签切过去时不能被地址栏抢焦点")
        background.window.makeKeyAndOrderFront(nil)
        spin()
        XCTAssertFalse(background.window.firstResponder is NSTextView)

        let window = session.openWindow(url: nil, configuration: session.configuration, contentSize: NSSize(width: 400, height: 300))
        XCTAssertTrue(window.isPopup)
        XCTAssertFalse(window.isShowingStartPage)

        // 普通的新标签（⌘T）照旧：显示起始页，要把焦点放进地址栏。
        let plain = session.openTab(in: host, url: nil)
        XCTAssertFalse(plain.isPopup)
        XCTAssertTrue(plain.isShowingStartPage)
    }

    /// window.open("") 的 about:blank 弹窗显示网页内容，不当成 ⇧⌘H 的起始页。
    func testBlankPopupShowsContent() {
        let host = session.openWindow(url: nil)
        let popup = session.openTab(in: host, url: nil, configuration: session.configuration)
        popup.webView.load(URLRequest(url: URL(string: "about:blank")!))
        spin(0.5)
        XCTAssertFalse(popup.isShowingStartPage)
        XCTAssertEqual(popup.displayURL?.absoluteString, "about:blank")
    }

    /// ⌘点按 / 中键点按：主框架链接在这里开新标签；target=_blank（targetFrame 为 nil）放行给 createWebViewWith，opener 才保留。
    func testLinkClickDecision() {
        typealias C = BrowserWindowController
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: .command, buttonNumber: 0), .openTab(background: true))
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: [.command, .shift], buttonNumber: 0), .openTab(background: false))
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: [], buttonNumber: 2), .openTab(background: true))
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: nil, flags: .command, buttonNumber: 0), .allow, "target=_blank 不截")
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: nil, flags: [], buttonNumber: 2), .allow)
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: false, flags: .command, buttonNumber: 0), .allow, "子框架里的链接照常")
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: .option, buttonNumber: 0), .download)
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: nil, flags: .option, buttonNumber: 0), .download)
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: false, flags: .option, buttonNumber: 0), .allow)
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: [], buttonNumber: 0), .allow)
    }

    // MARK: - 标签

    func testOpenTabSelectsForegroundAndKeepsBackground() {
        let host = session.openWindow(url: nil)
        let background = session.openTab(in: host, url: URL(string: "https://example.invalid/bg"), background: true)
        XCTAssertTrue(host.window.tabGroup?.selectedWindow === host.window, "后台打开留在原标签")
        let foreground = session.openTab(in: host, url: URL(string: "https://example.invalid/fg"))
        XCTAssertTrue(host.window.tabGroup?.selectedWindow === foreground.window)
        XCTAssertNotNil(background.webView.url)
    }

    // MARK: - 源代码窗口

    func testPageSourceWindowFocusFindAndClose() throws {
        let host = session.openWindow(url: nil)
        session.showSource("<p>hello</p>", title: "t", url: URL(string: "https://example.invalid/"), relativeTo: host.window)
        spin()
        let groups = session.windowGroups()
        XCTAssertEqual(groups.count, 2, "源代码窗口也算本环境的窗口，⌘` 能切过去")
        let sourceWindow = try XCTUnwrap(groups.first { $0 !== host.window })
        let source = try XCTUnwrap(sourceWindow.delegate as? PageSourceWindowController)
        XCTAssertEqual(sourceWindow.tabbingMode, .disallowed, "不和浏览窗口合并成标签")
        XCTAssertTrue(sourceWindow.firstResponder === source.textView)

        source.showFind(nil)
        XCTAssertEqual(source.textView.enclosingScrollView?.isFindBarVisible, true, "⌘F 打开源代码窗口自己的查找栏")

        // 源代码窗口在前时，⌘T 交给最前面的浏览窗口，不新建窗口。
        sourceWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(session.frontmostController === host)
        session.newTab(nil)
        XCTAssertEqual(host.window.tabbedWindows?.count, 2)
        XCTAssertEqual(session.openControllers.count, 2)

        source.closeTab(nil)
        spin()
        XCTAssertFalse(sourceWindow.isVisible)
        XCTAssertEqual(session.windowGroups().count, 1, "关掉后不再算进窗口列表")
    }

    // MARK: - 出错页网址、⇧⌘H

    func testFailedURLIsClearedByBackAndByOtherNavigation() throws {
        let controller = session.openWindow(url: nil)
        let failing = try XCTUnwrap(URL(string: "https://nonexistent.example.invalid/x"))
        controller.webView.load(URLRequest(url: failing))
        spin(until: { controller.failedURL != nil })
        XCTAssertEqual(controller.failedURL, failing, "出错页记下原本要打开的网址")
        spin(1)
        XCTAssertEqual(controller.failedURL, failing, "出错页自己的载入不清掉它")

        controller.webView.loadHTMLString("<p>other</p>", baseURL: URL(string: "https://other.example.invalid/"))
        spin(until: { controller.failedURL == nil })
        XCTAssertNil(controller.failedURL, "打开了别的网页，⌘R 不再重试旧网址")

        controller.webView.load(URLRequest(url: failing))
        spin(until: { controller.failedURL != nil })
        controller.goBack(nil)
        XCTAssertNil(controller.failedURL, "后退时立即清掉")
    }

    /// ⇧⌘H 留下的 about:blank：后退回到它时也显示起始页。（loadHTMLString 不进后退列表，这里用 loadSimulatedRequest。）
    func testBackToHomeEntryShowsStartPage() {
        let controller = session.openWindow(url: nil)
        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://a.example.invalid/")!), responseHTML: "<p>a</p>")
        spin(until: { controller.webView.url?.host == "a.example.invalid" && !controller.webView.isLoading })
        controller.goHome(nil)
        spin(until: { controller.webView.url?.absoluteString == "about:blank" && !controller.webView.isLoading })
        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://b.example.invalid/")!), responseHTML: "<p>b</p>")
        spin(until: { controller.webView.url?.host == "b.example.invalid" && !controller.webView.isLoading })
        XCTAssertNotNil(controller.displayURL)
        controller.goBack(nil)
        spin(until: { controller.webView.url?.absoluteString == "about:blank" && !controller.webView.isLoading })
        XCTAssertNil(controller.displayURL)
        XCTAssertTrue(controller.isShowingStartPage)
        XCTAssertEqual(controller.window.title, "起始页面")
    }

    // MARK: - 右键打开方式的定时器

    /// 连续两次右键：第一次的两秒定时器不能清掉第二次的设置。
    func testOpenModeTimerOnlyResetsItsOwnGeneration() {
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: WKWebViewConfiguration())
        let original = NSMenuItem(title: "o", action: #selector(ActionRecorder.fire(_:)), keyEquivalent: "")
        let recorder = ActionRecorder()
        original.target = recorder
        let forwarding = NSMenuItem(title: "f", action: nil, keyEquivalent: "")
        forwarding.representedObject = original

        webView.openInNewWindow(forwarding)
        XCTAssertTrue(webView.openNextAsWindow)
        spin(1.2)
        webView.openInBackgroundTab(forwarding)
        XCTAssertFalse(webView.openNextAsWindow, "新的一次先清掉上一次的方式")
        XCTAssertTrue(webView.openNextInBackgroundTab)
        spin(1.2)
        XCTAssertTrue(webView.openNextInBackgroundTab, "第一次的定时器到点了，但不能清掉第二次的设置")
        spin(1.2)
        XCTAssertFalse(webView.openNextInBackgroundTab, "第二次自己的定时器到点后复位")
    }

    // MARK: - 菜单置灰

    func testMenuItemsDisabledOnStartPage() throws {
        let controller = session.openWindow(url: nil)
        func enabled(_ action: Selector) -> Bool {
            controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        let pageOnly: [Selector] = [
            #selector(BrowserActions.zoomInPage(_:)), #selector(BrowserActions.zoomOutPage(_:)),
            #selector(BrowserActions.showFind(_:)), #selector(BrowserActions.findNextMatch(_:)), #selector(BrowserActions.findPreviousMatch(_:)),
            #selector(BrowserActions.duplicateTab(_:)), #selector(BrowserActions.goHome(_:)),
            #selector(BrowserActions.showWebInspector(_:)), #selector(BrowserActions.showJavaScriptConsole(_:)),
        ]
        for action in pageOnly { XCTAssertFalse(enabled(action), "起始页上 \(action) 应当置灰") }

        controller.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://page.example.invalid/"))
        spin(until: { controller.displayURL != nil })
        for action in pageOnly { XCTAssertTrue(enabled(action), "网页上 \(action) 应当可用") }

        controller.webView.pageZoom = 3
        XCTAssertFalse(enabled(#selector(BrowserActions.zoomInPage(_:))), "已经最大")
        controller.webView.pageZoom = 0.5
        XCTAssertFalse(enabled(#selector(BrowserActions.zoomOutPage(_:))), "已经最小")
    }

    func testGoHomeEnabledOnStartPageWhenProfileHasStartURL() throws {
        var profile = Profile(name: "home", mode: .ephemeral)
        profile.startURL = URL(string: "https://start.example.invalid/")
        let other = try Self.makeSession(profile)
        let controller = other.openWindow(url: nil)
        defer { controller.window.close() }
        XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserActions.goHome(_:)), keyEquivalent: "")))
    }

    // MARK: - 出错页不能盖掉正常页面（bad URL）

    func testErrorPageURLRule() throws {
        typealias C = BrowserWindowController
        let failing = try XCTUnwrap(URL(string: "https://failing.example.invalid/"))
        let pending = try XCTUnwrap(URL(string: "https://pending.example.invalid/"))
        let current = try XCTUnwrap(URL(string: "https://ippure.com/"))
        let bare = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
        let withURL = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSURLErrorFailingURLErrorKey: failing])
        let withString = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSURLErrorFailingURLStringErrorKey: failing.absoluteString])

        XCTAssertEqual(C.errorPageURL(for: withURL, provisional: true, pending: pending, current: current), failing)
        XCTAssertEqual(C.errorPageURL(for: withString, provisional: true, pending: pending, current: current), failing)
        XCTAssertEqual(C.errorPageURL(for: bare, provisional: true, pending: pending, current: current), pending, "没提交的导航：用这次要去的网址")
        XCTAssertNil(C.errorPageURL(for: bare, provisional: true, pending: nil, current: current), "不能拿正在显示的页面当失败网址")
        XCTAssertEqual(C.errorPageURL(for: bare, provisional: false, pending: nil, current: current), current, "已提交的导航失败：就是当前页面")
    }

    func testErrorReasonIsReadable() {
        typealias C = BrowserWindowController
        XCTAssertTrue(C.errorReason(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)).hasPrefix("网址无效（"))
        XCTAssertTrue(C.errorReason(NSError(domain: "WebKitErrorDomain", code: 101)).hasPrefix("网址无效"))
        XCTAssertTrue(C.errorReason(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)).hasPrefix("找不到服务器"))
        XCTAssertTrue(C.errorReason(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)).hasPrefix("无法连接服务器"))
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "原文"])
        XCTAssertEqual(C.errorReason(other), "原文")
    }

    /// 页面已经正常打开时，一次不带失败网址的 bad URL（例如网址表示不出来）不能用出错页把它盖掉。
    func testProvisionalFailureWithoutURLKeepsCurrentPage() throws {
        let controller = session.openWindow(url: nil)
        let page = try XCTUnwrap(URL(string: "https://ippure.example.invalid/"))
        controller.webView.loadSimulatedRequest(URLRequest(url: page), responseHTML: "<title>IPPure</title><p>ok</p>")
        spin(until: { controller.webView.url == page && !controller.webView.isLoading && controller.webView.title == "IPPure" })
        XCTAssertNil(controller.pendingNavigationURL, "提交后清空")

        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
        spin(0.8)
        XCTAssertNil(controller.failedURL, "没有生成出错页")
        XCTAssertFalse(controller.isLoadingErrorPage)
        XCTAssertEqual(controller.webView.url, page)
        XCTAssertEqual(controller.webView.title, "IPPure", "正常页面还在")

        // 已提交的导航失败（didFail）才用当前网址。
        controller.webView(controller.webView, didFail: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        XCTAssertEqual(controller.failedURL, page)
        spin(until: { controller.webView.title == "无法打开页面" })
        XCTAssertEqual(controller.webView.title, "无法打开页面")
    }

    /// 真实的导航失败：出错页挂在失败的网址上；出错页自己再失败时不再生成新的出错页。
    func testRealFailureUsesFailingURLAndErrorPageFailureDoesNotLoop() throws {
        let controller = session.openWindow(url: nil)
        let failing = try XCTUnwrap(URL(string: "https://nonexistent.example.invalid/x"))
        controller.webView.load(URLRequest(url: failing))
        spin(until: { controller.failedURL != nil })
        XCTAssertEqual(controller.failedURL, failing)
        spin(until: { controller.webView.title == "无法打开页面" })
        XCTAssertFalse(controller.isLoadingErrorPage, "出错页提交后复位")

        // 出错页正在载入时又失败：只记日志，不再生成出错页。
        controller.webView(controller.webView, didFail: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        XCTAssertTrue(controller.isLoadingErrorPage)
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSURLErrorFailingURLErrorKey: failing]))
        XCTAssertFalse(controller.isLoadingErrorPage)
    }

    // MARK: - 工具栏环境头像

    /// 圆形色块、左右留边：不会顶出新版工具栏左端胶囊的半圆。
    func testProfileBadgeIsCircularAndInset() {
        let badge = ProfileBadge(profile: Profile(name: "orange", mode: .persistent), accent: .systemOrange, isPrivate: false)
        badge.frame = NSRect(origin: .zero, size: badge.fittingSize)
        badge.layoutSubtreeIfNeeded()
        let dot = badge.convert(badge.dot.bounds, from: badge.dot)
        XCTAssertEqual(dot.width, ProfileBadge.dotDiameter)
        XCTAssertEqual(dot.height, ProfileBadge.dotDiameter)
        XCTAssertEqual(badge.dot.layer?.cornerRadius, ProfileBadge.dotDiameter / 2, "是圆，不是圆角方块")
        XCTAssertEqual(dot.minX, ProfileBadge.leadingInset, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(dot.minX, 7)
        XCTAssertEqual(dot.midY, badge.bounds.midY, accuracy: 0.5, "垂直居中")
        // 右边距按内容（栈视图）算；NSTextField 的 frame 比它的对齐矩形左右各宽 2pt，文字本身不越界。
        let content = badge.subviews.map(\.frame.maxX).max() ?? 0
        XCTAssertEqual(content, badge.bounds.width - ProfileBadge.trailingInset, accuracy: 0.5)
    }

    // MARK: - 地址栏 Esc、起始页信息

    func testEscapeInAddressBarCallsOnCancel() {
        let bar = AddressBar(isPrivate: false)
        var cancelled = false
        bar.onCancel = { cancelled = true }
        XCTAssertTrue(bar.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(cancelled)
    }

    /// 跟随代理时起始页显示按出口 IP 解析出来的语言和时区（RunnerMain 传进来的是 effectiveProfile）。
    func testStartPageShowsResolvedRegion() throws {
        let profile = Profile(name: "geo", mode: .ephemeral, languages: ["th-TH", "th"], timeZoneIdentifier: "Asia/Bangkok",
                              followProxyLanguages: true, followProxyTimeZone: true)
        let geo = try Self.makeSession(profile)
        XCTAssertTrue(geo.startPageDetails.contains("语言：th-TH, th · 时区：Asia/Bangkok（跟随代理出口）"), "\(geo.startPageDetails)")
        XCTAssertFalse(session.startPageDetails.contains { $0.hasPrefix("语言：") || $0.hasPrefix("时区：") }, "跟随系统时不显示")
    }

    /// 台式机和笔记本预设下，窗口中央的鼠标点击命中测试都落到 WebView（不会被起始页覆盖层拦下）。
    func testDesktopAndLaptopPresetsNeverBlockWebViewMouseHitTest() throws {
        for id in ["mac-studio-m2-ultra", "imac-24-m4", "mac-mini-m2", "mac-pro-m2-ultra", "macbook-pro-16-m4-max"] {
            let profile = Profile(name: id, mode: .ephemeral, deviceModel: id)
            let devSession = try Self.makeSession(profile)
            let controller = devSession.openWindow(url: nil)
            defer { controller.window.close() }
            let center = NSPoint(x: controller.webView.frame.midX, y: controller.webView.frame.midY)
            let hit = controller.window.contentView?.hitTest(center)
            XCTAssertNotNil(hit, id)
            XCTAssertTrue(hit === controller.webView || hit?.isDescendant(of: controller.webView) == true, "\(id): hit=\(String(describing: hit))")
        }
    }

    // MARK: - 脱敏诊断

    private func summaryJSON(_ controller: BrowserWindowController) throws -> [String: Any] {
        let text = controller.sanitizedDiagnosticsSummary()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    /// 只留 scheme://host/path：去掉账号密码、端口、query、fragment；没有 host 的网址不带内容。
    func testSanitizeURL() {
        let cases: [(String, String)] = [
            ("https://user:pass@Accounts.Google.com:443/o/oauth2/v2/auth?client_id=x&state=secret#frag", "https://accounts.google.com/o/oauth2/v2/auth"),
            ("https://example.com", "https://example.com/"),
            ("http://example.com/a%20b/c?x=1", "http://example.com/a%20b/c"),
            ("about:blank", "about:blank"),
            ("about:blank#token", "about:blank"),
            ("data:text/html,secret", "data:"),
            ("blob:https://example.com/6F9619FF-8B86-D011-B42D-00C04FC964FF", "blob:"),
            ("file:///Users/someone/Desktop/a.html", "file:"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(BrowserWindowController.sanitizeURL(URL(string: raw)), expected, raw)
        }
        XCTAssertNil(BrowserWindowController.sanitizeURL(nil))
    }

    /// 能力说明里的网址、UUID、IPv4 换成脱敏形式。
    func testRedactCapabilityDetails() {
        XCTAssertEqual(
            BrowserWindowController.redact("WKWebsiteDataStore(forIdentifier: 6F9619FF-8B86-D011-B42D-00C04FC964FF)"),
            "WKWebsiteDataStore(forIdentifier: <uuid>)"
        )
        XCTAssertEqual(BrowserWindowController.redact("socks5 203.0.113.10:1080"), "socks5 <ip>:1080")
        XCTAssertEqual(BrowserWindowController.redact("见 https://a.example/x?token=1，完毕"), "见 https://a.example/x，完毕")
    }

    /// 摘要是合法 JSON，有环境模式、内核 / UA、全部能力状态、窗口与视口尺寸、导航状态；
    /// 不含环境名、环境 id、网址的 query / fragment、账号或令牌。用本机回环上的小 HTTP 服务走一次真实的 302 → 200。
    func testSanitizedDiagnosticsSummaryHasNoSecrets() throws {
        let server = try LoopbackHTTPServer(routes: [
            "/start": .init(status: 302, headers: ["Location": "/signin/v2/identifier?continue=mail&email=alice%40gmail.com&token=secret-token"], body: ""),
            "/signin/v2/identifier": .init(status: 200, headers: ["Content-Type": "text/html"], body: "<p>sign in</p>"),
        ])
        defer { server.stop() }
        spin(until: { server.port != nil })
        let port = try XCTUnwrap(server.port)

        let profile = Profile(name: "alice@gmail.com", mode: .ephemeral)
        let signIn = try Self.makeSession(profile)
        let controller = signIn.openWindow(url: URL(string: "http://127.0.0.1:\(port)/start?session=abc123#frag"))
        defer { controller.window.close() }
        spin(until: { controller.navigationDiagnostics.lastMainFrameStatusCode == 200 && !controller.webView.isLoading })
        XCTAssertEqual(controller.navigationDiagnostics.lastMainFrameStatusCode, 200)
        XCTAssertEqual(controller.navigationDiagnostics.redirectCount, 1)

        let text = controller.sanitizedDiagnosticsSummary()
        for secret in ["alice", "secret-token", "continue", "abc123", "#frag", "\(port)", profile.id.uuidString] {
            XCTAssertFalse(text.contains(secret), "摘要里不能有 \(secret)")
        }
        let json = try summaryJSON(controller)
        let environment = try XCTUnwrap(json["environment"] as? [String: Any])
        XCTAssertEqual(environment["mode"] as? String, "ephemeral")
        XCTAssertEqual(environment["private"] as? Bool, true)
        XCTAssertEqual(environment["inspectable"] as? Bool, false)
        let engine = try XCTUnwrap(json["engine"] as? [String: Any])
        XCTAssertEqual(engine["userAgentApplicationName"] as? String, "Version/18.6 Safari/605.1.15")
        let capabilities = try XCTUnwrap(json["capabilities"] as? [String: [String: Any]])
        XCTAssertEqual(Set(capabilities.keys), Set(PrivacyFeature.allCases.map(\.rawValue)))
        XCTAssertTrue(capabilities.values.allSatisfy { $0["state"] is String })
        XCTAssertTrue(capabilities["proxy"]?["detail"] is NSNull, "代理说明里有服务器地址，不输出")
        let window = try XCTUnwrap(json["window"] as? [String: Any])
        XCTAssertEqual(window["isPopup"] as? Bool, false)
        XCTAssertEqual((window["frameSize"] as? [Int])?.count, 2)
        XCTAssertEqual((window["webViewViewport"] as? [Int])?.count, 2)
        XCTAssertTrue(json["device"] is NSNull, "没选机型")
        let navigation = try XCTUnwrap(json["navigation"] as? [String: Any])
        XCTAssertEqual(navigation["page"] as? String, "http://127.0.0.1/signin/v2/identifier")
        XCTAssertEqual(navigation["lastMainFrameStatusCode"] as? Int, 200)
        XCTAssertEqual(navigation["redirectCount"] as? Int, 1)
        XCTAssertEqual(navigation["showingErrorPage"] as? Bool, false)
        XCTAssertTrue(navigation["lastError"] is NSNull)
    }

    /// 重定向在一次导航内累加、新导航开始时清零；显示出错页时记下错误域和错误码（网址照样脱敏）。
    func testNavigationDiagnosticsCountRedirectsAndRecordErrors() throws {
        let controller = session.openWindow(url: nil)
        controller.webView(controller.webView, didStartProvisionalNavigation: nil)
        controller.webView(controller.webView, didReceiveServerRedirectForProvisionalNavigation: nil)
        controller.webView(controller.webView, didReceiveServerRedirectForProvisionalNavigation: nil)
        XCTAssertEqual(controller.navigationDiagnostics.redirectCount, 2)
        controller.webView(controller.webView, didStartProvisionalNavigation: nil)
        XCTAssertEqual(controller.navigationDiagnostics.redirectCount, 0)
        XCTAssertNil(controller.navigationDiagnostics.lastMainFrameStatusCode)

        let failing = URL(string: "https://login.example.invalid/challenge?token=abc#x")!
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: failing])
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertEqual(controller.navigationDiagnostics.lastErrorDomain, NSURLErrorDomain)
        XCTAssertEqual(controller.navigationDiagnostics.lastErrorCode, NSURLErrorCannotFindHost)
        spin(until: { controller.displayURL == failing && !controller.webView.isLoading })

        let text = controller.sanitizedDiagnosticsSummary()
        XCTAssertFalse(text.contains("token=abc"))
        let navigation = try XCTUnwrap(try summaryJSON(controller)["navigation"] as? [String: Any])
        XCTAssertEqual(navigation["page"] as? String, "https://login.example.invalid/challenge")
        XCTAssertEqual(navigation["showingErrorPage"] as? Bool, true)
        let lastError = try XCTUnwrap(navigation["lastError"] as? [String: Any])
        XCTAssertEqual(lastError["domain"] as? String, NSURLErrorDomain)
        XCTAssertEqual(lastError["code"] as? Int, NSURLErrorCannotFindHost)

        // 取消的载入不算错误，不覆盖上一次的记录。
        controller.webView(controller.webView, didFail: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertEqual(controller.navigationDiagnostics.lastErrorCode, NSURLErrorCannotFindHost)
    }

    /// 网页弹窗（登录弹窗等）和打开它的窗口同属一个会话：共用网站数据存储，跟着会话的 inspectable，
    /// 诊断里标成 isPopup，环境模式一致。
    func testPopupWindowsInheritSessionStateInDiagnostics() throws {
        session.setInspectable(true)
        let host = session.openWindow(url: nil)
        let popupTab = session.openTab(in: host, url: nil, configuration: session.configuration)
        let popupWindow = session.openWindow(url: nil, configuration: session.configuration, contentSize: NSSize(width: 480, height: 360))
        popupWindow.window.layoutIfNeeded()

        for popup in [popupTab, popupWindow] {
            XCTAssertTrue(popup.isPopup)
            XCTAssertTrue(popup.webView.isInspectable, "弹窗跟着会话打开检查")
            XCTAssertTrue(popup.webView.configuration.websiteDataStore === host.webView.configuration.websiteDataStore, "同一个网站数据存储")
            let json = try summaryJSON(popup)
            XCTAssertEqual((json["window"] as? [String: Any])?["isPopup"] as? Bool, true)
            XCTAssertEqual((json["environment"] as? [String: Any])?["inspectable"] as? Bool, true)
            XCTAssertEqual((json["environment"] as? [String: Any])?["mode"] as? String, session.profile.mode.rawValue)
        }
        XCTAssertEqual((try summaryJSON(host)["window"] as? [String: Any])?["isPopup"] as? Bool, false)
        let popupWindowJSON = try XCTUnwrap(try summaryJSON(popupWindow)["window"] as? [String: Any])
        XCTAssertEqual((popupWindowJSON["webViewViewport"] as? [Int])?.first, 480, "弹窗要求的宽度")

        session.setInspectable(false)
        XCTAssertFalse(popupTab.webView.isInspectable)
        XCTAssertFalse(popupWindow.webView.isInspectable)
    }

    /// 选了机型、窗口因屏幕放不下被等比缩小时，能力报告马上写明目标视口和实际视口（deviceModel 降为 degraded），
    /// 诊断摘要里也有两组尺寸；没缩放时保持机型模拟原来的结论。
    func testDeviceViewportScalingIsReported() throws {
        let id = "macbook-pro-16-m4-max"
        let model = try XCTUnwrap(MacDeviceModel.preset(id))
        let devSession = try Self.makeSession(Profile(name: "dev", mode: .ephemeral, deviceModel: id))
        let controller = devSession.openWindow(url: nil)
        defer { controller.window.close() }

        let target = model.viewportSize
        let actual = CGSize(width: (target.width * 0.75).rounded(.down), height: (target.height * 0.75).rounded(.down))
        devSession.recordViewportFit(.init(target: target, actual: actual))
        guard case .degraded(let text) = devSession.report[.deviceModel] else {
            return XCTFail("缩放后应为 degraded：\(devSession.report[.deviceModel].summary)")
        }
        XCTAssertTrue(text.contains("目标视口 \(Int(target.width))×\(Int(target.height))"), text)
        XCTAssertTrue(text.contains("实际视口缩小为 \(Int(actual.width))×\(Int(actual.height))"), text)

        let device = try XCTUnwrap(try summaryJSON(controller)["device"] as? [String: Any])
        XCTAssertEqual(device["model"] as? String, id)
        XCTAssertEqual(device["targetViewport"] as? [Int], [Int(target.width), Int(target.height)])
        XCTAssertEqual(device["newWindowViewport"] as? [Int], [Int(actual.width), Int(actual.height)])
        XCTAssertEqual(device["scaledToFitScreen"] as? Bool, true)

        // 合并规则本身。
        let fit = BrowserSession.ViewportFit(target: target, actual: actual)
        let unscaled = BrowserSession.ViewportFit(target: target, actual: target)
        XCTAssertEqual(BrowserSession.deviceModelState(simulation: .active("模拟"), fit: unscaled), .active("模拟"))
        XCTAssertEqual(BrowserSession.deviceModelState(simulation: .active("模拟"), fit: nil), .active("模拟"))
        guard case .degraded(let merged) = BrowserSession.deviceModelState(simulation: .active("模拟"), fit: fit) else { return XCTFail() }
        XCTAssertTrue(merged.hasPrefix("模拟；目标视口"), merged)
        guard case .unavailable = BrowserSession.deviceModelState(simulation: .unavailable("没有接口"), fit: fit) else { return XCTFail() }
        guard case .degraded = BrowserSession.deviceModelState(simulation: nil, fit: fit) else { return XCTFail() }
    }
}

/// 只监听 127.0.0.1 的极简 HTTP 服务：按路径（不含 query）返回固定响应，每个连接只答一次。测试用，不出本机。
private final class LoopbackHTTPServer: @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String]
        var body: String
    }

    private let listener: NWListener
    private let routes: [String: Response]
    private let queue = DispatchQueue(label: "safarier.test.http")
    private let lock = NSLock()
    private var boundPort: UInt16?

    var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    init(routes: [String: Response]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port?.rawValue else { return }
            self.lock.lock()
            self.boundPort = port
            self.lock.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [routes] data, _, _, _ in
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
            let response = routes[path] ?? Response(status: 404, headers: [:], body: "not found")
            let body = Data(response.body.utf8)
            var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
            for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
