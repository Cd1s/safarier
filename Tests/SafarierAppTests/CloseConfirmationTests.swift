import XCTest
import AppKit
import SafarierCore
@testable import Safarier

/// 关闭窗口 / 退出前的确认：`shouldConfirmBeforeClose` 的规则、确认框文字和按钮、「不再询问」和「关闭窗口前询问」开关，
/// 以及 ⌘W / 红叉 / ⇧⌘W / ⌘Q 各条路径。代码直接调 window.close() 不经过确认（Agent、测试用）。
@MainActor
final class CloseConfirmationTests: XCTestCase {
    private var environment: TestBrowserEnvironment!

    override func setUp() async throws {
        environment = try TestBrowserEnvironment()
    }

    override func tearDown() async throws {
        environment.tearDown()
        environment = nil
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: - 规则

    func testShouldConfirmBeforeCloseRules() {
        func ask(_ enabled: Bool = true, tabs: Int, browsing: Bool, last: Bool) -> Bool {
            BrowserSession.shouldConfirmBeforeClose(enabled: enabled, tabCount: tabs, browsingPage: browsing, closesEnvironment: last)
        }
        XCTAssertTrue(ask(tabs: 1, browsing: false, last: true), "关掉环境的最后一个窗口（或 ⌘Q）：就算是空白起始页也问")
        XCTAssertTrue(ask(tabs: 3, browsing: false, last: false), "多标签窗口")
        XCTAssertTrue(ask(tabs: 1, browsing: true, last: false), "正在浏览网页的窗口")
        XCTAssertFalse(ask(tabs: 1, browsing: false, last: false), "环境还有别的窗口时，关一个空白起始页窗口不问")
        XCTAssertFalse(ask(false, tabs: 5, browsing: true, last: true), "关掉「关闭窗口前询问」后一律不问")
        XCTAssertFalse(ask(tabs: 0, browsing: false, last: true), "没有标签可关")
    }

    func testConfirmationTextForPersistentAndPrivateEnvironments() {
        let persistent = BrowserSession.closeConfirmationText(profileName: "工作", isPrivate: false, tabCount: 3, closesEnvironment: true)
        XCTAssertEqual(persistent.message, "确认关闭环境「工作」的浏览窗口吗？")
        XCTAssertEqual(persistent.informative, "当前共有 3 个打开的标签页。\n已自动保存当前打开的标签页与登录状态，下次可在「历史记录」中一键恢复。")

        let privateText = BrowserSession.closeConfirmationText(profileName: "无痕", isPrivate: true, tabCount: 1, closesEnvironment: true)
        XCTAssertEqual(privateText.message, "确认关闭环境「无痕」的浏览窗口吗？")
        XCTAssertEqual(privateText.informative, "这是临时无痕环境，关闭后所有网站数据将立即销毁。", "单标签不提标签数")

        // 环境还有别的窗口时不说「数据销毁」「已保存会话」这类只在环境关闭时才成立的话。
        let otherWindowPrivate = BrowserSession.closeConfirmationText(profileName: "无痕", isPrivate: true, tabCount: 2, closesEnvironment: false).informative
        XCTAssertFalse(otherWindowPrivate.contains("立即销毁"))
        XCTAssertTrue(otherWindowPrivate.hasPrefix("当前共有 2 个打开的标签页。"))
        XCTAssertFalse(BrowserSession.closeConfirmationText(profileName: "工作", isPrivate: false, tabCount: 2, closesEnvironment: false).informative.contains("已自动保存"))
    }

    func testAlertButtonsKeysAndSuppression() throws {
        let session = try environment.makeSession(mode: .persistent, name: "工作")
        let alert = session.makeCloseConfirmationAlert(tabCount: 2, closesEnvironment: true)
        XCTAssertEqual(alert.messageText, "确认关闭环境「工作」的浏览窗口吗？")
        XCTAssertEqual(alert.buttons.map(\.title), ["关闭", "取消"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "「关闭」是默认按钮（回车）")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}", "「取消」接 Esc")
        XCTAssertTrue(alert.showsSuppressionButton)
        XCTAssertEqual(alert.suppressionButton?.title, "不再询问（直接关闭）")

        XCTAssertTrue(session.confirmsBeforeClose, "默认开启")
        alert.suppressionButton?.state = .on
        XCTAssertFalse(session.acceptCloseConfirmation(alert, response: .alertSecondButtonReturn), "取消不关")
        XCTAssertTrue(session.confirmsBeforeClose, "取消时不采用「不再询问」")
        XCTAssertTrue(session.acceptCloseConfirmation(alert, response: .alertFirstButtonReturn))
        XCTAssertFalse(session.confirmsBeforeClose, "勾了「不再询问」再关闭：之后直接关")
        XCTAssertEqual(environment.preferences.object(forKey: BrowserSession.confirmBeforeCloseKey) as? Bool, false, "存进偏好")
    }

    func testMenuToggleDefaultsOnAndFlips() throws {
        let fileMenu = try XCTUnwrap(BrowserMenu.make().items.first { $0.title == "文件" }?.submenu)
        let menuItem = try XCTUnwrap(fileMenu.items.first { $0.action == #selector(BrowserActions.toggleConfirmBeforeClose(_:)) })
        XCTAssertEqual(menuItem.title, "关闭窗口前询问")

        let session = try environment.makeSession(mode: .persistent)
        let controller = session.openWindow(url: nil)
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.state, .on)
        controller.toggleConfirmBeforeClose(menuItem)
        _ = controller.validateMenuItem(menuItem)
        XCTAssertEqual(menuItem.state, .off)
        XCTAssertFalse(session.confirmsBeforeClose)
        session.toggleConfirmBeforeClose(nil)
        XCTAssertTrue(session.confirmsBeforeClose)
    }

    // MARK: - ⌘W / 标签栏 ×

    func testClosingOneTabOfSeveralNeverAsks() throws {
        let session = try environment.makeSession(mode: .persistent)
        let host = session.openWindow(url: nil)
        TestBrowserEnvironment.load(host, url: url("https://tab.example.invalid/"), title: "Tab")
        let middle = session.openTab(in: host, url: nil)
        _ = session.openTab(in: host, url: nil)
        XCTAssertTrue(middle.windowShouldClose(middle.window), "多标签窗口里只关一个标签，不问")
        XCTAssertNil(middle.window.attachedSheet)

        middle.closeTab(nil)
        TestBrowserEnvironment.spin()
        XCTAssertEqual(session.openControllers.count, 2)
    }

    func testClosingLastWindowAsksAndOnlyClosesAfterConfirming() throws {
        let session = try environment.makeSession(mode: .persistent, name: "工作")
        let controller = session.openWindow(url: nil)
        let page = url("https://last.example.invalid/")
        TestBrowserEnvironment.load(controller, url: page, title: "Last")

        XCTAssertFalse(controller.windowShouldClose(controller.window), "⌘W 关最后一个窗口：先确认")
        var alert = try XCTUnwrap(controller.closeConfirmation)
        XCTAssertTrue(controller.window.attachedSheet === alert.window, "确认框是窗口上的 sheet")
        XCTAssertEqual(alert.informativeText, "已自动保存当前打开的标签页与登录状态，下次可在「历史记录」中一键恢复。")
        XCTAssertFalse(controller.windowShouldClose(controller.window), "已经在问时不重复弹")

        controller.window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        TestBrowserEnvironment.spin()
        XCTAssertEqual(session.openControllers.count, 1, "取消：窗口还在")
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertEqual(session.history.lastSessionTabURLs, [], "没关就不记上次会话")

        controller.closeTab(nil)
        alert = try XCTUnwrap(controller.closeConfirmation)
        controller.window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        TestBrowserEnvironment.spin()
        XCTAssertTrue(session.openControllers.isEmpty, "确认后关掉")
        XCTAssertEqual(session.history.lastSessionTabURLs, [page], "关掉环境的最后一个窗口时记下上次会话")
    }

    /// 红叉、⌘W 在 AppKit 里是同一个关闭动作：按触发事件落在哪里分辨。
    func testCloseButtonClickIsRecognizedFromTheTriggeringEvent() throws {
        let session = try environment.makeSession(mode: .persistent)
        let controller = session.openWindow(url: nil)
        let window = controller.window
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let center = try XCTUnwrap(button.superview).convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, window number: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: number, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        XCTAssertTrue(BrowserWindowController.isCloseButtonClick(mouse(.leftMouseUp, at: center, window: window.windowNumber), in: window))
        XCTAssertFalse(BrowserWindowController.isCloseButtonClick(mouse(.leftMouseUp, at: NSPoint(x: 300, y: 200), window: window.windowNumber), in: window),
                       "点在别处（标签栏上的 × 等）")
        XCTAssertFalse(BrowserWindowController.isCloseButtonClick(mouse(.leftMouseUp, at: center, window: window.windowNumber + 999), in: window), "别的窗口")
        let commandW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)
        XCTAssertFalse(BrowserWindowController.isCloseButtonClick(commandW, in: window), "⌘W")
        XCTAssertFalse(BrowserWindowController.isCloseButtonClick(nil, in: window))
    }

    func testRedCloseButtonClosesWholeWindowLikeSafari() throws {
        let session = try environment.makeSession(mode: .ephemeral, name: "无痕")
        let other = session.openWindow(url: nil)
        let host = session.openWindow(url: nil)
        _ = session.openTab(in: host, url: nil)
        let selected = session.openTab(in: host, url: nil)
        XCTAssertEqual(host.tabs.count, 3)

        XCTAssertFalse(selected.shouldClose(fromCloseButton: true), "红叉：由控制器自己关整个窗口")
        let alert = try XCTUnwrap(selected.closeConfirmation, "关多标签窗口：先确认")
        XCTAssertEqual(alert.informativeText, "当前共有 3 个打开的标签页。\n环境的其他窗口还开着，网站数据保留到环境关闭为止。")
        selected.window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        TestBrowserEnvironment.spin()
        XCTAssertEqual(session.openControllers.count, 1, "红叉关掉整个窗口（所有标签），不只当前标签")
        XCTAssertTrue(session.openControllers.first === other)

        // 剩下这个是空白起始页但已经是最后一个窗口：照样问，说明是无痕环境。
        XCTAssertFalse(other.shouldClose(fromCloseButton: true))
        XCTAssertEqual(other.closeConfirmation?.informativeText, "这是临时无痕环境，关闭后所有网站数据将立即销毁。")
    }

    func testBlankWindowWithOtherWindowsOpenClosesWithoutAsking() throws {
        let session = try environment.makeSession(mode: .persistent)
        _ = session.openWindow(url: nil)
        let blank = session.openWindow(url: nil)
        XCTAssertTrue(blank.windowShouldClose(blank.window))
        blank.requestCloseWindow()
        TestBrowserEnvironment.spin()
        XCTAssertNil(blank.closeConfirmation)
        XCTAssertEqual(session.openControllers.count, 1)
    }

    func testTurningConfirmationOffClosesImmediately() throws {
        let session = try environment.makeSession(mode: .persistent)
        session.confirmsBeforeClose = false
        let host = session.openWindow(url: nil)
        let page = url("https://off.example.invalid/")
        TestBrowserEnvironment.load(host, url: page, title: "Off")
        _ = session.openTab(in: host, url: nil)
        host.requestCloseWindow()
        TestBrowserEnvironment.spin()
        XCTAssertNil(host.closeConfirmation)
        XCTAssertTrue(session.openControllers.isEmpty)
        XCTAssertEqual(session.history.lastSessionTabURLs, [page], "不问也照样记下上次会话")
    }

    func testProgrammaticCloseNeverAsks() throws {
        let session = try environment.makeSession(mode: .persistent)
        let controller = session.openWindow(url: nil)
        TestBrowserEnvironment.load(controller, url: url("https://agent.example.invalid/"), title: "Agent")
        controller.window.close()
        TestBrowserEnvironment.spin()
        XCTAssertNil(controller.closeConfirmation, "Agent / 测试直接 close() 不弹确认")
        XCTAssertTrue(session.openControllers.isEmpty)
    }

    // MARK: - ⌘Q

    func testQuitAsksOnFrontWindowAndRepliesWithTheChoice() throws {
        let session = try environment.makeSession(mode: .persistent)
        var replies: [Bool] = []
        session.replyToTermination = { replies.append($0) }
        XCTAssertEqual(session.applicationShouldTerminate(NSApp), .terminateNow, "没有浏览窗口时直接退出")

        let controller = session.openWindow(url: nil)
        _ = session.openTab(in: controller, url: nil)
        XCTAssertEqual(session.applicationShouldTerminate(NSApp), .terminateLater)
        let host = try XCTUnwrap(session.openControllers.first { $0.closeConfirmation != nil })
        let alert = try XCTUnwrap(host.closeConfirmation)
        XCTAssertEqual(alert.informativeText, "当前共有 2 个打开的标签页。\n已自动保存当前打开的标签页与登录状态，下次可在「历史记录」中一键恢复。")
        XCTAssertEqual(session.applicationShouldTerminate(NSApp), .terminateCancel, "已经在问时不叠第二个")
        host.window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        TestBrowserEnvironment.spin()
        XCTAssertEqual(replies, [false], "取消：不退出")

        XCTAssertEqual(session.applicationShouldTerminate(NSApp), .terminateLater)
        let again = try XCTUnwrap(host.closeConfirmation)
        host.window.endSheet(again.window, returnCode: .alertFirstButtonReturn)
        TestBrowserEnvironment.spin()
        XCTAssertEqual(replies, [false, true], "确认：退出")

        session.confirmsBeforeClose = false
        XCTAssertEqual(session.applicationShouldTerminate(NSApp), .terminateNow)
    }
}
