import XCTest
import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

/// 测试用的浏览会话：元数据放临时目录、偏好用独立的 suite。持久环境的网站数据也用非持久的存储，
/// 不在本机 WebKit 目录里留下测试数据；会话本身仍按持久环境工作（历史落盘、记上次会话）。
@MainActor
final class TestBrowserEnvironment {
    let root: URL
    let workspace: SafarierWorkspace
    let suiteName = "SafarierTests-\(UUID().uuidString)"
    let preferences: UserDefaults
    private(set) var sessions: [BrowserSession] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SafarierBrowserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = SafarierWorkspace(root: root)
        preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    func makeSession(mode: ProfileMode, name: String = "测试环境") throws -> BrowserSession {
        try makeSession(profile: Profile(name: name, mode: mode))
    }

    /// 同一个环境再开一次会话（模拟下次启动）。
    func makeSession(profile: Profile) throws -> BrowserSession {
        _ = NSApplication.shared
        var webKitProfile = profile
        webKitProfile.mode = .ephemeral
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "20621.3.11.11.3", installedSafari: "27.0", safariStagedWebKit: "20625.1.29.18.28")
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), userAgentVersion: choice)
        let output = try factory.make(profile: webKitProfile, proxy: nil, processLanguages: [])
        let session = BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics(),
                                     workspace: workspace, preferences: preferences)
        sessions.append(session)
        return session
    }

    func tearDown() {
        for session in sessions {
            for controller in session.openControllers {
                if let sheet = controller.window.attachedSheet { controller.window.endSheet(sheet, returnCode: .cancel) }
                controller.window.close()
            }
        }
        sessions = []
        preferences.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    static func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    static func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { spin(0.05) }
        return condition()
    }

    /// 载入一张带标题的本地页面（https 网址，不走网络）。
    static func load(_ controller: BrowserWindowController, url: URL, title: String) {
        controller.webView.loadHTMLString("<!doctype html><title>\(title)</title><p>\(title)</p>", baseURL: url)
        wait { controller.webView.url == url && !controller.webView.isLoading }
    }
}

/// 浏览历史：载入的网页按环境记下（出错页不记），⌘Y 历史记录视图（搜索、分组、点开、删除、清除），
/// 历史记录菜单（⌘Y、最近 15 条、清除），上次会话的标签在环境关闭时记下并能一键恢复。
@MainActor
final class BrowsingHistoryTests: XCTestCase {
    private var environment: TestBrowserEnvironment!

    override func setUp() async throws {
        environment = try TestBrowserEnvironment()
    }

    override func tearDown() async throws {
        environment.tearDown()
        environment = nil
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: - 记录

    func testLoadedPagesAreRecordedToDiskButErrorPagesAreNot() throws {
        let session = try environment.makeSession(mode: .persistent)
        let controller = session.openWindow(url: nil)
        let page = url("https://history.example.invalid/article")
        TestBrowserEnvironment.load(controller, url: page, title: "第一篇文章")
        XCTAssertTrue(TestBrowserEnvironment.wait { session.history.entries.first?.url == page })
        XCTAssertEqual(session.history.entries.first?.title, "第一篇文章")
        let file = environment.workspace.historyURL(for: session.profile.id)
        XCTAssertEqual(session.history.fileURL, file)
        XCTAssertEqual(BrowsingHistoryStore(fileURL: file).entries.map(\.url), [page], "持久环境的历史写进 history/<PROFILE_ID>.json")

        // 打不开的网页显示出错页，出错页不进历史记录。
        let broken = url("https://unreachable.example.invalid/")
        controller.openURL(broken)
        XCTAssertTrue(TestBrowserEnvironment.wait(15) { controller.failedURL == broken && !controller.webView.isLoading })
        TestBrowserEnvironment.spin(0.3)
        XCTAssertEqual(session.history.entries.map(\.url), [page])
    }

    func testPrivateEnvironmentKeepsHistoryInMemoryOnly() throws {
        let session = try environment.makeSession(mode: .ephemeral)
        let controller = session.openWindow(url: nil)
        TestBrowserEnvironment.load(controller, url: url("https://private.example.invalid/"), title: "无痕")
        XCTAssertTrue(TestBrowserEnvironment.wait { session.history.entries.count == 1 })
        XCTAssertNil(session.history.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.workspace.historyDirectory.path), "临时环境的历史绝不落盘")
    }

    // MARK: - ⌘Y 历史记录视图

    func testCommandYTogglesHistoryPageInCurrentTab() throws {
        let session = try environment.makeSession(mode: .persistent)
        let controller = session.openWindow(url: nil)
        let page = url("https://toggle.example.invalid/")
        TestBrowserEnvironment.load(controller, url: page, title: "切换")
        XCTAssertTrue(TestBrowserEnvironment.wait { !session.history.entries.isEmpty })
        let menuItem = NSMenuItem(title: "显示所有历史记录", action: #selector(BrowserActions.showHistory(_:)), keyEquivalent: "y")

        controller.showHistory(nil)
        let history = try XCTUnwrap(controller.historyPage)
        XCTAssertTrue(controller.showingHistory)
        XCTAssertFalse(history.isHidden)
        XCTAssertFalse(controller.isShowingStartPage)
        XCTAssertNil(controller.displayURL, "历史记录视图不是网页")
        XCTAssertEqual(controller.window.title, "历史记录")
        XCTAssertEqual(history.rows.first, .header("今天"))
        XCTAssertEqual(history.entry(at: 1)?.url, page)
        XCTAssertEqual(controller.webView.url, page, "下面的网页保留着")
        _ = controller.validateMenuItem(menuItem)
        XCTAssertEqual(menuItem.title, "隐藏历史记录")

        controller.showHistory(nil)
        XCTAssertFalse(controller.showingHistory)
        XCTAssertTrue(history.isHidden)
        XCTAssertEqual(controller.displayURL, page)
        XCTAssertEqual(controller.window.title, "切换")
        _ = controller.validateMenuItem(menuItem)
        XCTAssertEqual(menuItem.title, "显示所有历史记录")
    }

    func testHistoryPageSearchesGroupsOpensAndDeletes() throws {
        let session = try environment.makeSession(mode: .persistent)
        let controller = session.openWindow(url: nil)
        let now = Date()
        let alpha = url("https://alpha.example.invalid/")
        let beta = url("https://beta.example.invalid/docs")
        session.history.recordVisit(alpha, title: "Alpha 首页", at: now.addingTimeInterval(-86_400 * 3))
        session.history.recordVisit(beta, title: "Beta Docs", at: now.addingTimeInterval(-60))

        controller.displayHistory()
        let history = try XCTUnwrap(controller.historyPage)
        XCTAssertTrue(controller.window.firstResponder === history.searchField.currentEditor() || controller.window.firstResponder === history.searchField,
                      "⌘Y 后焦点在搜索框")
        XCTAssertEqual(history.rows, [.header("今天"), .entry(session.history.entries[0]), .header("更早"), .entry(session.history.entries[1])])
        XCTAssertTrue(history.emptyLabel.isHidden)

        history.searchField.stringValue = "DOCS"
        history.reload()
        XCTAssertEqual(history.rows.compactMap { if case .entry(let entry) = $0 { return entry.url } else { return nil } }, [beta], "按网址和标题过滤，不分大小写")
        history.searchField.stringValue = "没有这个"
        history.reload()
        XCTAssertFalse(history.emptyLabel.isHidden)
        XCTAssertEqual(history.emptyLabel.stringValue, "没有找到与「没有这个」相符的历史记录")
        history.searchField.stringValue = ""
        history.reload()

        // 右键菜单：打开 / 拷贝网址 / 删除；删除单条。
        XCTAssertEqual(history.makeContextMenu().items.map(\.title), ["打开", "拷贝网址", "删除"])
        history.delete(row: 3)
        XCTAssertEqual(session.history.entries.map(\.url), [beta])
        XCTAssertEqual(history.rows.count, 2, "删除后列表跟着刷新")
        XCTAssertFalse(history.tableView(history.tableView, shouldSelectRow: 0), "分组标题不能选")
        XCTAssertTrue(history.tableView(history.tableView, isGroupRow: 0))

        // 点开：在这个标签里打开，历史记录视图收起。
        history.open(row: 1)
        XCTAssertFalse(controller.showingHistory)
        XCTAssertTrue(history.isHidden)
        XCTAssertTrue(TestBrowserEnvironment.wait(15) { controller.webView.url == beta || controller.failedURL == beta })
    }

    func testClearHistoryButtonAsksThenClears() throws {
        let session = try environment.makeSession(mode: .persistent)
        let controller = session.openWindow(url: nil)
        session.history.recordVisit(url("https://clear.example.invalid/"), title: "Clear")
        session.history.setLastSessionTabURLs([url("https://clear.example.invalid/")])
        controller.displayHistory()
        let history = try XCTUnwrap(controller.historyPage)
        XCTAssertTrue(history.clearButton.isEnabled)
        XCTAssertEqual(history.clearButton.title, "清除历史记录…")

        history.clearButton.performClick(nil)
        var alert = try XCTUnwrap(controller.clearHistoryConfirmation, "先确认")
        XCTAssertEqual(alert.buttons.map(\.title), ["清除历史记录", "取消"])
        controller.window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        TestBrowserEnvironment.spin()
        XCTAssertEqual(session.history.entries.count, 1, "取消就不清")

        controller.clearHistory(nil)
        alert = try XCTUnwrap(controller.clearHistoryConfirmation)
        controller.window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        TestBrowserEnvironment.spin()
        XCTAssertEqual(session.history.entries, [])
        XCTAssertEqual(session.history.lastSessionTabURLs, [])
        XCTAssertFalse(history.emptyLabel.isHidden)
        XCTAssertEqual(history.emptyLabel.stringValue, "还没有历史记录")
        XCTAssertFalse(history.clearButton.isEnabled)
    }

    // MARK: - 历史记录菜单

    func testHistoryMenuHasCommandYRecentEntriesAndClearItem() throws {
        let menu = try XCTUnwrap(BrowserMenu.make().items.first { $0.title == "历史记录" }?.submenu)
        let show = try XCTUnwrap(menu.items.first { $0.action == #selector(BrowserActions.showHistory(_:)) })
        XCTAssertEqual(show.title, "显示所有历史记录")
        XCTAssertEqual(show.keyEquivalent, "y")
        XCTAssertEqual(show.keyEquivalentModifierMask, .command)
        XCTAssertEqual(menu.items.first { $0.action == #selector(BrowserActions.restoreLastSession(_:)) }?.title, "重新打开上次会话的所有标签页")
        XCTAssertEqual(menu.items.last?.title, "清除历史记录…")
        XCTAssertTrue(menu.delegate === HistoryMenuDelegate.shared, "菜单打开前刷新最近访问")

        let entries = (0..<20).map { BrowsingHistoryEntry(url: url("https://recent\($0).example.invalid/"), title: "最近 \($0)", visitedAt: Date()) }
        let fixed = menu.items.count
        BrowserMenu.updateRecentHistory(in: menu, entries: entries)
        BrowserMenu.updateRecentHistory(in: menu, entries: entries)
        let recent = menu.items.filter { $0.action == #selector(BrowserActions.openHistoryEntry(_:)) }
        XCTAssertEqual(recent.count, 15, "最多列 15 条，反复刷新不重复")
        XCTAssertEqual(recent.map { $0.representedObject as? URL }, entries.prefix(15).map(\.url))
        XCTAssertEqual(recent.first?.title, "最近 0")
        let clearIndex = try XCTUnwrap(menu.items.firstIndex { $0.action == #selector(BrowserActions.clearHistory(_:)) })
        XCTAssertEqual(menu.items.firstIndex { $0 === recent.last }.map { $0 + 2 }, clearIndex, "最近访问在「清除历史记录…」上面，中间隔一条分隔线")

        BrowserMenu.updateRecentHistory(in: menu, entries: [])
        XCTAssertEqual(menu.items.count, fixed, "没有历史时去掉动态项")
    }

    func testRecentEntryAndMenuValidationRouteThroughController() throws {
        let session = try environment.makeSession(mode: .persistent)
        let controller = session.openWindow(url: nil)
        let restore = NSMenuItem(title: "重新打开上次会话的所有标签页", action: #selector(BrowserActions.restoreLastSession(_:)), keyEquivalent: "")
        let clear = NSMenuItem(title: "清除历史记录…", action: #selector(BrowserActions.clearHistory(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(restore), "没有上次会话时不可用")
        XCTAssertFalse(controller.validateMenuItem(clear))

        let target = url("https://menu.example.invalid/")
        session.history.recordVisit(target, title: "Menu")
        XCTAssertTrue(controller.validateMenuItem(clear))
        let item = NSMenuItem(title: "Menu", action: #selector(BrowserActions.openHistoryEntry(_:)), keyEquivalent: "")
        item.representedObject = target
        controller.openHistoryEntry(item)
        XCTAssertTrue(TestBrowserEnvironment.wait(15) { controller.webView.url == target || controller.failedURL == target })
    }

    // MARK: - 上次会话

    func testLastSessionIsSavedWhenEnvironmentClosesAndRestoredInOneClick() throws {
        let session = try environment.makeSession(mode: .persistent)
        session.confirmsBeforeClose = false
        let first = session.openWindow(url: nil)
        let a = url("https://session-a.example.invalid/")
        let b = url("https://session-b.example.invalid/")
        TestBrowserEnvironment.load(first, url: a, title: "A")
        let second = session.openTab(in: first, url: nil)
        TestBrowserEnvironment.load(second, url: b, title: "B")
        _ = session.openTab(in: first, url: nil)   // 空白起始页不算会话标签
        XCTAssertEqual(session.openTabURLs, [a, b])

        first.requestCloseWindow()
        TestBrowserEnvironment.spin()
        XCTAssertTrue(session.openControllers.isEmpty, "关窗口关掉了所有标签")
        XCTAssertEqual(session.history.lastSessionTabURLs, [a, b])
        let file = environment.workspace.historyURL(for: session.profile.id)
        XCTAssertEqual(BrowsingHistoryStore(fileURL: file).lastSessionTabURLs, [a, b], "写进了磁盘")

        // 下次启动：恢复到空白起始页所在的窗口里。
        let next = try environment.makeSession(profile: session.profile)
        XCTAssertEqual(next.history.lastSessionTabURLs, [a, b])
        let host = next.openWindow(url: nil)
        let restore = NSMenuItem(title: "", action: #selector(BrowserActions.restoreLastSession(_:)), keyEquivalent: "")
        XCTAssertTrue(host.validateMenuItem(restore))
        let restored = next.restoreLastSession(in: host)
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.first === host, "第一个网址开在空白起始页里")
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertTrue(TestBrowserEnvironment.wait(15) { restored.map(\.sessionURL) == [a, b] })
    }

    func testQuitSavesAllOpenTabsButPrivateEnvironmentKeepsNothing() throws {
        let session = try environment.makeSession(mode: .persistent)
        let one = session.openWindow(url: nil)
        let other = session.openWindow(url: nil)
        let a = url("https://quit-a.example.invalid/")
        let b = url("https://quit-b.example.invalid/")
        TestBrowserEnvironment.load(one, url: a, title: "A")
        TestBrowserEnvironment.load(other, url: b, title: "B")
        session.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(Set(session.history.lastSessionTabURLs), [a, b], "⌘Q 时窗口都还开着：全部记下")

        let privateSession = try environment.makeSession(mode: .ephemeral)
        let tab = privateSession.openWindow(url: nil)
        TestBrowserEnvironment.load(tab, url: a, title: "A")
        privateSession.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(privateSession.history.lastSessionTabURLs, [], "临时环境不留上次会话")
    }
}
