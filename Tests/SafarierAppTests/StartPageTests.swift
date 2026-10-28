import XCTest
import AppKit
import WebKit
@testable import SafarierCore
import SafarierWebKit
@testable import Safarier

/// 起始页（对标真 Safari 起始页）：个人收藏的持久化与网格、建议卡片、隐私报告、「编辑」面板，以及点击规则
/// ——显示时磁贴可点，点了立刻在同窗口的网页里打开并隐藏起始页，隐藏后不拦截网页的任何点击。
@MainActor
final class StartPageTests: XCTestCase {
    private var directory: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("start-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows = []
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent(StartPageStore.fileName) }

    private func makeStore() -> StartPageStore { StartPageStore(fileURL: fileURL) }

    private let details = ["持久环境 · 网站数据保存在这个环境里", "出站：订阅「机场」节点「🇯🇵 Tokyo」（经 sing-box）", "机型：Mac mini (M4 · 4K Retina)",
                           "语言：ja-JP, ja · 时区：Asia/Tokyo（跟随代理出口）"]

    private func makeView(store: StartPageStore, profile: Profile = Profile(name: "工作", mode: .persistent),
                          details: [String]? = nil, size: NSSize = NSSize(width: 1000, height: 900)) -> StartPageView {
        let view = StartPageView(profile: profile, accent: .systemOrange, details: details ?? self.details, store: store)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// 放进一个真的窗口：容器里像浏览窗口一样放网页（在内容栈里）和叠在上面的起始页。
    private func host(_ view: StartPageView, webView: BrowserWebView? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: view.frame.size))
        if let webView {
            let content = NSStackView(views: [webView])
            content.frame = container.bounds
            container.addSubview(content)
        }
        container.addSubview(view)
        window.contentView = container
        view.frame = container.bounds
        view.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        windows.append(window)
        return window
    }

    /// 在视图中心点一下：从窗口内容视图做真实的 hitTest，把按下 / 抬起事件交给命中的视图。
    /// （不用 window.sendEvent：测试进程成不了前台应用，AppKit 会把非活跃窗口的第一次点击只当成激活。）
    private func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let contentView = window.contentView!
        guard let target = contentView.hitTest(contentView.convert(point, from: nil)) else {
            return XCTFail("点不到任何视图")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            type == .leftMouseDown ? target.mouseDown(with: event) : target.mouseUp(with: event)
        }
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - 持久化

    func testDefaultFavoritesAndSections() {
        let store = StartPageStore(fileURL: nil)
        XCTAssertEqual(store.favorites.count, 16)
        XCTAssertEqual(Set(store.favorites.map(\.url)).count, 16)
        let byTitle = Dictionary(uniqueKeysWithValues: store.favorites.map { ($0.title, $0.url.absoluteString) })
        XCTAssertEqual(byTitle["IPCheck.ing"], "https://ipcheck.ing")
        let ipCheck = store.favorites.first { $0.title == "IPCheck.ing" }
        XCTAssertEqual(ipCheck?.symbol, "network")
        XCTAssertEqual(ipCheck?.background, "#4F46E5")
        XCTAssertEqual(ipCheck?.foreground, "#FFFFFF")
        XCTAssertEqual(byTitle["LINUX DO"], "https://linux.do")
        XCTAssertEqual(byTitle["Claude"], "https://claude.ai")
        for favorite in store.favorites {
            XCTAssertEqual(favorite.url.scheme, "https", favorite.title)
            XCTAssertNotNil(favorite.symbol ?? favorite.glyph, favorite.title)
            XCTAssertTrue(favorite.background.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil, favorite.background)
        }
        for section in StartPageSection.allCases { XCTAssertTrue(store.isVisible(section)) }
    }

    func testAddRemoveRestoreAndPersist() throws {
        let store = makeStore()
        let added = try store.addFavorite(title: "  ", address: "example.com\u{200B}").get()
        XCTAssertEqual(added.title, "example.com", "名字空着用域名")
        XCTAssertEqual(added.url.absoluteString, "https://example.com")
        XCTAssertEqual(store.addFavorite(title: "x", address: "https://example.com/"), .failure(.duplicate))
        XCTAssertEqual(store.addFavorite(title: "x", address: "hello"), .failure(.invalidAddress))
        XCTAssertEqual(store.addFavorite(title: "x", address: "ftp://example.org"), .failure(.invalidAddress))
        store.setSection(.suggestions, visible: false)

        let reopened = makeStore()
        XCTAssertEqual(reopened.favorites.count, 17)
        XCTAssertEqual(reopened.favorites.last?.url, added.url)
        XCTAssertFalse(reopened.isVisible(.suggestions))
        XCTAssertTrue(reopened.isVisible(.favorites))

        reopened.removeFavorite(url: URL(string: "https://example.com/")!)
        XCTAssertEqual(makeStore().favorites.count, 16, "删除也写回磁盘")
        reopened.removeFavorite(url: StartPageStore.defaultFavorites[0].url)
        XCTAssertEqual(makeStore().favorites.count, 15)
        reopened.restoreDefaultFavorites()
        XCTAssertEqual(makeStore().favorites, StartPageStore.defaultFavorites)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore()
        XCTAssertEqual(store.favorites, StartPageStore.defaultFavorites)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "not json", "没有改动前不覆盖")
    }

    private var retiredDefaultURL: URL {
        URL(string: "https://\u{69}\u{70}\u{70}\u{75}\u{72}\u{65}.com")!
    }

    func testRetiredDefaultFavoriteMigratesAndPersistsWithoutLosingSettings() throws {
        let custom = StartPageStore.customFavorite(title: "My site", url: URL(string: "https://example.com/work")!, host: "example.com")
        let replacement = try XCTUnwrap(StartPageStore.defaultFavorites.first { $0.title == "IPCheck.ing" })
        for suffix in ["", "/"] {
            let retired = StartPageFavorite(title: "Previous checker", url: URL(string: retiredDefaultURL.absoluteString + suffix)!,
                                            glyph: "I", background: "#4F46E5", foreground: "#FFFFFF")
            let previous = StartPageSettings(favorites: [custom, retired], hiddenSections: [.suggestions])
            try JSONEncoder().encode(previous).write(to: fileURL)

            let migrated = makeStore()
            XCTAssertEqual(migrated.favorites, [custom, replacement])
            XCTAssertEqual(migrated.settings.hiddenSections, [.suggestions])
            let saved = try JSONDecoder().decode(StartPageSettings.self, from: Data(contentsOf: fileURL))
            XCTAssertEqual(saved, migrated.settings)
            XCTAssertEqual(makeStore().settings, migrated.settings)
        }
    }

    func testMigrationKeepsExistingReplacementWithoutAddingDuplicate() throws {
        let retired = StartPageFavorite(title: "Previous checker", url: retiredDefaultURL,
                                        glyph: "I", background: "#4F46E5", foreground: "#FFFFFF")
        let existing = StartPageStore.customFavorite(title: "My IP tool", url: URL(string: "https://ipcheck.ing/")!, host: "ipcheck.ing")
        let previous = StartPageSettings(favorites: [retired, existing], hiddenSections: [.privacyReport])
        try JSONEncoder().encode(previous).write(to: fileURL)

        let migrated = makeStore()
        XCTAssertEqual(migrated.favorites, [existing])
        XCTAssertEqual(migrated.settings.hiddenSections, previous.hiddenSections)
        XCTAssertEqual(makeStore().settings, migrated.settings)
    }

    func testMigrationLeavesCustomPathsAndUnrelatedFavoritesUntouched() throws {
        let custom = StartPageStore.customFavorite(title: "Saved report", url: retiredDefaultURL.appendingPathComponent("report"), host: retiredDefaultURL.host!)
        let previous = StartPageSettings(favorites: [custom], hiddenSections: [.favorites])
        let originalData = try JSONEncoder().encode(previous)
        try originalData.write(to: fileURL)

        XCTAssertEqual(makeStore().settings, previous)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData, "没有旧默认项时不重写用户设置")
    }

    func testCustomFavoriteLooksStable() {
        let first = StartPageStore.customFavorite(title: "Example", url: URL(string: "https://example.com")!, host: "example.com")
        let second = StartPageStore.customFavorite(title: "Example", url: URL(string: "https://example.com")!, host: "example.com")
        XCTAssertEqual(first, second, "颜色按域名固定，不随启动变化")
        XCTAssertEqual(first.glyph, "E")
    }

    func testChangeNotificationIsPosted() {
        let store = StartPageStore(fileURL: nil)
        let posted = expectation(forNotification: StartPageStore.didChangeNotification, object: store)
        store.setSection(.privacyReport, visible: false)
        wait(for: [posted], timeout: 1)
    }

    // MARK: - 布局

    func testFavoritesGridIsEightColumnsByTwoRows() throws {
        let view = makeView(store: StartPageStore(fileURL: nil))
        XCTAssertEqual(view.tiles.count, 16)
        XCTAssertEqual(view.visibleFavoriteCount, 16)
        let visible = view.tiles.filter { !$0.isHidden }
        XCTAssertEqual(Set(visible.map(\.frame.minY)).count, 2, "两行")
        XCTAssertEqual(Set(visible.map(\.frame.minX)).count, 8, "八列")
        let first = try XCTUnwrap(view.tiles.first)
        XCTAssertEqual(first.iconView.frame.size, NSSize(width: 64, height: 64))
        XCTAssertEqual(first.iconView.layer?.cornerRadius, 14)
        XCTAssertEqual(first.iconView.layer?.cornerCurve, .continuous)
        XCTAssertEqual(first.titleLabel.font?.pointSize, 12)
        XCTAssertEqual(view.sectionTitles[.favorites]?.stringValue, "个人收藏")
        XCTAssertEqual(view.sectionTitles[.favorites]?.font, NSFont.systemFont(ofSize: 19, weight: .bold))
        XCTAssertEqual(view.showAllButton?.isHidden, true, "刚好两行时不需要「显示全部」")
        // 内容最宽 840，居中。
        let xs = visible.map(\.frame.minX)
        XCTAssertLessThanOrEqual((xs.max() ?? 0) + first.frame.width - (xs.min() ?? 0), StartPageView.maxContentWidth)
    }

    func testNarrowWindowUsesFewerColumnsAndShowAll() throws {
        let view = makeView(store: StartPageStore(fileURL: nil), size: NSSize(width: 560, height: 800))
        let columns = StartPageView.columns(for: 560 - 48)
        XCTAssertEqual(columns, 5)
        XCTAssertEqual(view.tiles.filter { !$0.isHidden }.count, 10)
        let showAll = try XCTUnwrap(view.showAllButton)
        XCTAssertFalse(showAll.isHidden)
        showAll.performClick(nil)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.showsAllFavorites)
        XCTAssertEqual(view.tiles.filter { !$0.isHidden }.count, 16)
    }

    func testSuggestionCardsAndPrivacyReport() throws {
        let profile = Profile(name: "工作", mode: .persistent, spi: .defaultFeatures)
        let view = makeView(store: StartPageStore(fileURL: nil), profile: profile)
        XCTAssertEqual(view.cards.count, 3)
        for card in view.cards { XCTAssertEqual(card.frame.size, StartPageView.cardSize) }
        XCTAssertEqual(view.cards[0].titleLabel.stringValue, "工作")
        XCTAssertEqual(view.cards[0].subtitleLabel.stringValue, "持久环境 · Mac mini (M4 · 4K Retina)")
        XCTAssertEqual(view.cards[0].sourceLabel.stringValue, "来自 Safarier 环境护盾 ›")
        XCTAssertEqual(view.cards[1].titleLabel.stringValue, "订阅「机场」节点「🇯🇵 Tokyo」（经 sing-box）")
        XCTAssertEqual(view.cards[1].subtitleLabel.stringValue, "语言：ja-JP, ja · 时区：Asia/Tokyo（跟随代理出口）")
        XCTAssertEqual(view.cards[1].sourceLabel.stringValue, "点击检测出口 IP ›")
        XCTAssertEqual(view.cards[2].titleLabel.stringValue, "Claude")

        let banner = try XCTUnwrap(view.banner)
        XCTAssertEqual(banner.frame.height, 92)
        XCTAssertEqual(banner.protectionValue.stringValue, "4 项原生保护")
        XCTAssertEqual(banner.protectionDetail.stringValue, "Safari 原生防指纹护盾已阻止跨站追踪器剖析此环境")
        XCTAssertEqual(banner.isolationDetail.stringValue, "独立数据沙盒 · 字体白名单隔离 · 代理断连阻断（Fail-Closed）")
        XCTAssertEqual(view.sectionTitles[.suggestions]?.stringValue, "建议")
        XCTAssertEqual(view.sectionTitles[.privacyReport]?.stringValue, "隐私报告")
    }

    /// 隐私报告只写这个环境真开着的东西：直连不写代理阻断，没开 afp 不写已阻止追踪。
    func testPrivacyReportReflectsActualSettings() throws {
        let profile = Profile(name: "裸奔", mode: .ephemeral, spi: [])
        let view = makeView(store: StartPageStore(fileURL: nil), profile: profile, details: ["临时环境 · 关闭窗口后不留任何网站数据", "出站：直连"])
        let banner = try XCTUnwrap(view.banner)
        XCTAssertEqual(banner.protectionValue.stringValue, "0 项原生保护")
        XCTAssertEqual(banner.protectionDetail.stringValue, "高级隐私保护没有开启，可以在环境设置里打开")
        XCTAssertEqual(banner.isolationValue.stringValue, "临时沙盒")
        XCTAssertEqual(banner.isolationDetail.stringValue, "独立数据沙盒")
        XCTAssertEqual(view.cards[1].subtitleLabel.stringValue, "语言和时区跟随系统")
    }

    func testSectionsFollowStore() {
        let store = StartPageStore(fileURL: nil)
        let view = makeView(store: store)
        store.setSection(.suggestions, visible: false)
        XCTAssertTrue(view.cards.isEmpty)
        XCTAssertNil(view.sectionTitles[.suggestions])
        store.setSection(.favorites, visible: false)
        XCTAssertTrue(view.tiles.isEmpty)
        store.setSection(.privacyReport, visible: false)
        XCTAssertNil(view.banner)
        store.setSection(.favorites, visible: true)
        XCTAssertEqual(view.tiles.count, 16)
    }

    func testEditButtonPinnedBottomRight() {
        let view = makeView(store: StartPageStore(fileURL: nil))
        XCTAssertEqual(view.editButton.title, "编辑")
        XCTAssertEqual(view.editButton.frame.maxX, view.bounds.maxX - 24)
        XCTAssertEqual(view.editButton.frame.minY, 20, "距底边 20（非翻转坐标）")
        XCTAssertEqual(view.editButton.frame.size, StartPageView.editButtonSize)
    }

    func testPrivateProfileUsesDarkBackground() {
        let view = makeView(store: StartPageStore(fileURL: nil), profile: Profile(name: "无痕", mode: .ephemeral))
        XCTAssertTrue(view.usesDarkBackground)
        view.updateLayer()
        XCTAssertEqual(view.layer?.backgroundColor, StartPageView.darkBackground.cgColor)
    }

    // MARK: - 点击

    func testTileClickUsesCallbackAndHides() throws {
        let view = makeView(store: StartPageStore(fileURL: nil))
        var opened: URL?
        view.onOpenURL = { opened = $0 }
        let window = host(view)
        let ipCheck = try XCTUnwrap(view.tiles.first { $0.favorite.title == "IPCheck.ing" })
        click(ipCheck, in: window)
        XCTAssertEqual(opened?.absoluteString, "https://ipcheck.ing")
        XCTAssertTrue(view.isHidden, "点了立刻隐藏，不挡网页")
    }

    /// 没设回调：在同一窗口里找到 BrowserWebView 直接载入（不用改标签控制器）。
    func testTileClickLoadsSiblingWebViewWithoutCallback() throws {
        let view = makeView(store: StartPageStore(fileURL: nil))
        let webView = BrowserWebView(frame: NSRect(origin: .zero, size: view.frame.size), configuration: WKWebViewConfiguration())
        let window = host(view, webView: webView)
        XCTAssertTrue(StartPageView.findWebView(near: view) === webView)
        let github = try XCTUnwrap(view.tiles.first { $0.favorite.title == "GitHub" })
        click(github, in: window)
        XCTAssertEqual(webView.url?.absoluteString, "https://github.com/", "WebKit 把网址规范成带 / 的形式")
        XCTAssertTrue(view.isHidden)
    }

    func testCardClickOpensExitIPCheck() {
        let view = makeView(store: StartPageStore(fileURL: nil))
        var opened: [URL] = []
        view.onOpenURL = { opened.append($0) }
        let window = host(view)
        click(view.cards[0], in: window)
        XCTAssertTrue(opened.isEmpty, "当前环境卡片只展示")
        click(view.cards[1], in: window)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://ipcheck.ing"])
        view.isHidden = false
        click(view.cards[2], in: window)
        XCTAssertEqual(opened.last?.absoluteString, "https://claude.ai")
    }

    /// 显示时磁贴接住点击；隐藏或淡出后一律不接，网页的点击不会被拦住。
    func testHitTestOnlyWhileVisible() throws {
        let view = makeView(store: StartPageStore(fileURL: nil))
        _ = host(view)
        let tile = try XCTUnwrap(view.tiles.first)
        let point = view.superview!.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), from: tile)
        XCTAssertTrue(view.hitTest(point) === tile)
        XCTAssertTrue(view.hitTest(view.superview!.convert(NSPoint(x: view.editButton.bounds.midX, y: view.editButton.bounds.midY), from: view.editButton)) === view.editButton)
        view.alphaValue = 0
        XCTAssertNil(view.hitTest(point))
        view.alphaValue = 1
        view.isHidden = true
        XCTAssertNil(view.hitTest(point))
    }

    func testTileContextMenu() throws {
        let store = StartPageStore(fileURL: nil)
        let view = makeView(store: store)
        let tile = try XCTUnwrap(view.tiles.first { $0.favorite.title == "YouTube" })
        let menu = tile.makeMenu()
        XCTAssertEqual(menu.items.map(\.title), ["打开", "删除此收藏", "", "恢复默认收藏"])
        var opened: URL?
        view.onOpenURL = { opened = $0 }
        menu.performActionForItem(at: 0)
        XCTAssertEqual(opened?.absoluteString, "https://www.youtube.com")

        menu.performActionForItem(at: 1)
        XCTAssertFalse(store.favorites.contains { $0.title == "YouTube" })
        XCTAssertEqual(view.tiles.count, 15, "删除后起始页跟着刷新")
        let another = try XCTUnwrap(view.tiles.first).makeMenu()
        another.performActionForItem(at: 3)
        XCTAssertEqual(store.favorites, StartPageStore.defaultFavorites)
        XCTAssertEqual(view.tiles.count, 16)
    }

    func testEditorTogglesSectionsAndAddsFavorites() throws {
        let store = StartPageStore(fileURL: nil)
        let editor = StartPageEditor(store: store)
        editor.loadView()
        XCTAssertEqual(editor.sectionToggles.count, 3)
        let suggestions = try XCTUnwrap(editor.sectionToggles[.suggestions])
        XCTAssertEqual(suggestions.state, .on)
        suggestions.state = .off
        editor.toggleSection(suggestions)
        XCTAssertFalse(store.isVisible(.suggestions))

        editor.nameField.stringValue = "示例"
        editor.addressField.stringValue = "example.org"
        editor.addFavorite(nil)
        XCTAssertEqual(store.favorites.last?.title, "示例")
        XCTAssertEqual(store.favorites.last?.url.absoluteString, "https://example.org")
        XCTAssertEqual(editor.messageLabel.stringValue, "已添加「示例」")
        XCTAssertEqual(editor.addressField.stringValue, "", "添加后清空输入框")

        editor.addressField.stringValue = "not a url"
        editor.addFavorite(nil)
        XCTAssertEqual(editor.messageLabel.textColor, .systemRed)
        editor.addressField.stringValue = "https://example.org/"
        editor.addFavorite(nil)
        XCTAssertEqual(editor.messageLabel.stringValue, "这个网站已经在个人收藏里了")
        editor.restoreDefaults(nil)
        XCTAssertEqual(store.favorites, StartPageStore.defaultFavorites)
    }

    /// 编辑按钮弹出设置面板（按钮能接到点击由 testHitTestOnlyWhileVisible 覆盖；
    /// 这里用 performClick：给 NSButton 发 mouseDown 会进入它自己的跟踪循环）。
    func testEditButtonShowsEditor() {
        let view = makeView(store: StartPageStore(fileURL: nil))
        _ = host(view)
        view.editButton.performClick(nil)
        spin()
        XCTAssertNotNil(view.editPopover)
        XCTAssertTrue(view.editPopover?.contentViewController is StartPageEditor)
        view.editPopover?.close()
    }

    // MARK: - 浏览窗口里

    /// 真的浏览窗口：新标签显示起始页；从起始页打开网址后网页载入、起始页隐藏，标签控制器的状态跟着走。
    func testStartPageInsideBrowserWindow() throws {
        let profile = Profile(name: "start", mode: .ephemeral)
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/26.2 Safari/605.1.15")
        let session = BrowserSession(profile: profile, output: try factory.make(profile: profile, proxy: nil, processLanguages: []),
                                     outboundDescription: "直连", diagnostics: SPIDiagnostics())
        let controller = session.openWindow(url: nil)
        defer { controller.window.close() }
        XCTAssertTrue(controller.isShowingStartPage)
        let startPage = try XCTUnwrap(Self.find(StartPageView.self, in: controller.window.contentView))
        XCTAssertTrue(StartPageView.findWebView(near: startPage) === controller.webView)
        startPage.open(URL(string: "https://example.invalid/from-start-page")!)
        XCTAssertEqual(controller.webView.url?.absoluteString, "https://example.invalid/from-start-page")
        XCTAssertFalse(controller.isShowingStartPage)
        XCTAssertNil(startPage.hitTest(NSPoint(x: 10, y: 10)))
    }

    private static func find<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}
