import XCTest
import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

/// 照 Safari 还原的浏览操作：菜单快捷键、⌘N 独立窗口、恢复关闭的标签、⌘1…⌘9、循环显示窗口、右键菜单、地址栏粘贴并前往、
/// 文本缩放、网页检查器、页面原文。
@MainActor
final class SafariBehaviorTests: XCTestCase {
    private var session: BrowserSession!

    override func setUp() async throws {
        _ = NSApplication.shared
        let profile = Profile(name: "test", mode: .ephemeral)
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "20621.3.11.11.3", installedSafari: "27.0", safariStagedWebKit: "20625.1.29.18.28")
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), userAgentVersion: choice)
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

    // MARK: - 菜单栏

    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    private func item(_ items: [NSMenuItem], _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        items.first { $0.action == action && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
    }

    func testMenuShortcutsMatchSafari() {
        let items = allItems(BrowserMenu.make())
        let expected: [(Selector, String, NSEvent.ModifierFlags, Bool)] = [
            (#selector(BrowserActions.newWindow(_:)), "n", .command, false),
            (#selector(BrowserActions.newTab(_:)), "t", .command, false),
            (#selector(BrowserActions.reopenClosedTab(_:)), "t", [.command, .shift], false),
            (#selector(BrowserActions.focusLocation(_:)), "l", .command, false),
            (#selector(BrowserActions.closeTab(_:)), "w", .command, false),
            (#selector(BrowserActions.closeOtherTabs(_:)), "w", [.command, .option], false),
            (#selector(BrowserActions.closeWindow(_:)), "w", [.command, .shift], false),
            (#selector(BrowserActions.savePageAs(_:)), "s", .command, false),
            (#selector(BrowserActions.printPage(_:)), "p", .command, false),
            (#selector(BrowserActions.showFind(_:)), "f", .command, false),
            (#selector(BrowserActions.findNextMatch(_:)), "g", .command, false),
            (#selector(BrowserActions.findPreviousMatch(_:)), "g", [.command, .shift], false),
            (#selector(BrowserActions.useSelectionForFind(_:)), "e", .command, false),
            (#selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift], false),
            (#selector(BrowserActions.stopLoading(_:)), ".", .command, false),
            (#selector(BrowserActions.reloadPage(_:)), "r", .command, false),
            (#selector(BrowserActions.reloadFromOrigin(_:)), "r", [.command, .option], false),
            (#selector(BrowserActions.reloadFromOrigin(_:)), "r", [.command, .shift], true),
            (#selector(BrowserActions.actualSizePage(_:)), "0", .command, false),
            (#selector(BrowserActions.zoomInPage(_:)), "+", .command, false),
            (#selector(BrowserActions.zoomInPage(_:)), "=", .command, true),
            (#selector(BrowserActions.zoomOutPage(_:)), "-", .command, false),
            (#selector(BrowserActions.zoomTextIn(_:)), "+", [.command, .option], false),
            (#selector(BrowserActions.zoomTextIn(_:)), "=", [.command, .option], true),
            (#selector(BrowserActions.zoomTextOut(_:)), "-", [.command, .option], false),
            (#selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], false),
            (#selector(BrowserActions.goBack(_:)), "[", .command, false),
            (#selector(BrowserActions.goBack(_:)), BrowserMenu.leftArrow, .command, true),
            (#selector(BrowserActions.goForward(_:)), "]", .command, false),
            (#selector(BrowserActions.goForward(_:)), BrowserMenu.rightArrow, .command, true),
            (#selector(BrowserActions.goHome(_:)), "h", [.command, .shift], false),
            (#selector(BrowserActions.showWebInspector(_:)), "i", [.command, .option], false),
            (#selector(BrowserActions.showJavaScriptConsole(_:)), "c", [.command, .option], false),
            (#selector(BrowserActions.showPageSource(_:)), "u", [.command, .option], false),
            (#selector(BrowserActions.copyDiagnostics(_:)), "d", [.command, .option, .shift], false),
            (#selector(NSWindow.performMiniaturize(_:)), "m", .command, false),
            (#selector(BrowserActions.cycleWindowsForward(_:)), "`", .command, false),
            (#selector(BrowserActions.cycleWindowsForward(_:)), "·", .command, true),
            (#selector(BrowserActions.cycleWindowsBackward(_:)), "`", [.command, .shift], true),
            (#selector(BrowserActions.cycleWindowsBackward(_:)), "~", [.command, .shift], true),
            (#selector(BrowserActions.cycleWindowsBackward(_:)), "·", [.command, .shift], true),
            (#selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift], false),
            (#selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift], false),
            (#selector(NSWindow.selectNextTab(_:)), "\t", .control, true),
            (#selector(NSWindow.selectPreviousTab(_:)), "\u{19}", [.control, .shift], true),
            (#selector(BrowserActions.toggleDownloads(_:)), "l", [.command, .option], false),
        ]
        for (action, key, modifiers, isHidden) in expected {
            guard let found = item(items, action, key, modifiers) else {
                XCTFail("缺少 \(action) \(modifiers.rawValue) \(key.debugDescription)")
                continue
            }
            XCTAssertEqual(found.isHidden, isHidden, "\(action) \(key.debugDescription)")
            if isHidden { XCTAssertTrue(found.allowsKeyEquivalentWhenHidden, "\(action) 隐藏项的快捷键要生效") }
        }
        for selector in [#selector(BrowserActions.exportPDF(_:)), #selector(BrowserActions.duplicateTab(_:)),
                         #selector(NSWindow.moveTabToNewWindow(_:)), #selector(NSWindow.mergeAllWindows(_:)),
                         #selector(NSWindow.toggleTabBar(_:)), #selector(BrowserActions.toggleInspectable(_:))] {
            XCTAssertTrue(items.contains { $0.action == selector && !$0.isHidden }, "缺少菜单项 \(selector)")
        }
        // ⌘1…⌘8 第 1…8 个标签，⌘9 最后一个。
        for number in 1...9 {
            let entry = item(items, #selector(BrowserActions.selectTabByNumber(_:)), "\(number)")
            XCTAssertEqual(entry?.tag, number)
            XCTAssertEqual(entry?.isHidden, true)
        }
    }

    /// 同一个按键组合只能对应一个动作，否则后面的永远不会触发。
    func testNoConflictingKeyEquivalents() {
        var seen: [String: Selector] = [:]
        for entry in allItems(BrowserMenu.make()) where !entry.keyEquivalent.isEmpty {
            guard let action = entry.action else { continue }
            let key = "\(entry.keyEquivalentModifierMask.rawValue)-\(entry.keyEquivalent)"
            if let existing = seen[key] {
                XCTAssertEqual(existing, action, "快捷键冲突：\(entry.keyEquivalent.debugDescription) 同时给了 \(existing) 和 \(action)")
            }
            seen[key] = action
        }
    }

    // MARK: - 窗口与标签

    /// ⌘N 永远是独立窗口（即使系统设置为总是用标签页打开），之后 tabbingMode 恢复成 automatic，⌘T 照常并进标签。
    func testNewWindowIsIndependentAndTabbingIsRestored() {
        let first = session.openWindow(url: nil)
        let second = session.openWindow(url: nil)
        XCTAssertFalse(first.window.tabbedWindows?.contains(second.window) ?? false)
        XCTAssertEqual(second.window.tabbingMode, .automatic)
        let tab = session.openTab(in: second, url: nil)
        XCTAssertTrue(second.window.tabbedWindows?.contains(tab.window) ?? false)
    }

    func testClosedTabStackKeepsLatestTwenty() {
        for index in 1...25 { session.recordClosedTab(URL(string: "https://example.com/\(index)")) }
        session.recordClosedTab(URL(string: "about:blank"))
        session.recordClosedTab(nil)
        XCTAssertEqual(session.closedTabURLs.count, BrowserSession.closedTabLimit)
        XCTAssertEqual(session.closedTabURLs.first?.path, "/6")
        XCTAssertEqual(session.closedTabURLs.last?.path, "/25")
    }

    /// 关掉一个打开过网页的标签，⇧⌘T 在同一窗口里把它恢复成新标签。
    func testReopenClosedTabRestoresURLInSameWindow() throws {
        let host = session.openWindow(url: nil)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/closed-tab"))
        let tab = session.openTab(in: host, url: url)
        XCTAssertEqual(tab.webView.url, url)
        tab.window.close()
        spin()
        XCTAssertEqual(session.closedTabURLs.last, url)

        let reopened = try XCTUnwrap(session.reopenClosedTab(in: host))
        XCTAssertEqual(reopened.webView.url, url)
        XCTAssertTrue(host.window.tabbedWindows?.contains(reopened.window) ?? false)
        XCTAssertFalse(session.closedTabURLs.contains(url))
        XCTAssertNil(session.reopenClosedTab(in: host), "没有可恢复的标签时什么都不做")
    }

    func testSelectTabByNumber() throws {
        let host = session.openWindow(url: nil)
        let tabs = [host] + (0..<3).map { _ in session.openTab(in: host, url: nil) }
        XCTAssertEqual(host.tabs.count, 4)
        host.selectTab(number: 9)
        XCTAssertTrue(host.window.tabGroup?.selectedWindow === host.tabs.last, "⌘9 是最后一个标签")
        host.selectTab(number: 2)
        XCTAssertTrue(host.window.tabGroup?.selectedWindow === host.tabs[1])
        host.selectTab(number: 7)
        XCTAssertTrue(host.window.tabGroup?.selectedWindow === host.tabs[1], "超出标签数时不切换")
        XCTAssertEqual(tabs.count, 4)

        XCTAssertEqual(BrowserWindowController.tab(number: 1, in: ["a", "b", "c"]), "a")
        XCTAssertEqual(BrowserWindowController.tab(number: 3, in: ["a", "b", "c"]), "c")
        XCTAssertNil(BrowserWindowController.tab(number: 4, in: ["a", "b", "c"]))
        XCTAssertEqual(BrowserWindowController.tab(number: 9, in: ["a", "b"]), "b")
        XCTAssertNil(BrowserWindowController.tab(number: 1, in: [String]()))
    }

    func testCloseOtherTabsKeepsCurrent() {
        let host = session.openWindow(url: nil)
        let current = session.openTab(in: host, url: nil)
        _ = session.openTab(in: host, url: nil)
        current.closeOtherTabs(nil)
        spin()
        XCTAssertEqual(session.openControllers.count, 1)
        XCTAssertTrue(session.openControllers.first === current)
    }

    func testDuplicateTabOpensSameURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/dup"))
        let host = session.openWindow(url: url)
        host.duplicateTab(nil)
        let copy = try XCTUnwrap(session.openControllers.last)
        XCTAssertFalse(copy === host)
        XCTAssertEqual(copy.webView.url, url)
        XCTAssertTrue(host.window.tabbedWindows?.contains(copy.window) ?? false)
    }

    // MARK: - 循环显示窗口

    func testWindowCyclingOrder() {
        let a = NSObject(), b = NSObject(), c = NSObject()
        XCTAssertTrue(WindowCycler.target(in: [a, b, c], forward: true) === c, "向前：最后面的拿到最前")
        XCTAssertTrue(WindowCycler.target(in: [a, b, c], forward: false) === b, "向后：第二个拿到最前")
        XCTAssertNil(WindowCycler.target(in: [a], forward: true))
        XCTAssertNil(WindowCycler.target(in: [NSObject](), forward: false))
    }

    func testNextSafarierProcessWrapsAround() {
        XCTAssertEqual(WindowCycler.nextProcess([10, 30], current: 20, forward: true), 30)
        XCTAssertEqual(WindowCycler.nextProcess([10, 20], current: 30, forward: true), 10, "首尾相接")
        XCTAssertEqual(WindowCycler.nextProcess([20, 30], current: 10, forward: false), 30)
        XCTAssertEqual(WindowCycler.nextProcess([20], current: 10, forward: false), 20)
        XCTAssertNil(WindowCycler.nextProcess([], current: 10, forward: true))
        XCTAssertNil(WindowCycler.nextProcess([10], current: 10, forward: true))
    }

    func testCycleShortcutDirection() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 50
            ))
        }
        XCTAssertEqual(WindowCycler.direction(for: try key("`", .command)), true)
        XCTAssertEqual(WindowCycler.direction(for: try key("·", .command)), true, "中文输入法下的 ⌘`")
        XCTAssertEqual(WindowCycler.direction(for: try key("~", [.command, .shift])), false)
        XCTAssertEqual(WindowCycler.direction(for: try key("·", [.command, .shift])), false)
        XCTAssertEqual(WindowCycler.direction(for: try key("～", [.command, .shift])), false)
        XCTAssertNil(WindowCycler.direction(for: try key("`", [.command, .option])))
        XCTAssertNil(WindowCycler.direction(for: try key("a", .command)))
        XCTAssertNil(WindowCycler.direction(for: try key("`", [])))
    }

    /// 同一组标签只算一个窗口；⌘` 依次把最后面的窗口拿到最前。
    func testSessionWindowGroupsCollapseTabsAndRotate() {
        let first = session.openWindow(url: nil)
        _ = session.openTab(in: first, url: nil)
        let second = session.openWindow(url: nil)
        spin()
        let groups = session.windowGroups()
        XCTAssertEqual(groups.count, 2, "两个窗口（其中一个有两个标签）")
        XCTAssertTrue(groups.first === second.window, "最新打开的窗口在最前")
        session.cycleWindows(forward: true)
        spin()
        XCTAssertTrue(session.windowGroups().first?.tabGroup === first.window.tabGroup, "⌘` 把后面的窗口拿到最前")
        session.cycleWindows(forward: false)
        spin()
        XCTAssertTrue(session.windowGroups().first === second.window, "⇧⌘` 反过来")
    }

    // MARK: - 右键菜单

    private func menu(_ identifiers: [String], titles: [String: String] = [:]) -> NSMenu {
        let menu = NSMenu()
        for identifier in identifiers {
            if identifier == "-" { menu.addItem(.separator()); continue }
            let entry = NSMenuItem(title: titles[identifier] ?? identifier, action: #selector(ActionRecorder.fire(_:)), keyEquivalent: "")
            entry.identifier = NSUserInterfaceItemIdentifier(identifier)
            menu.addItem(entry)
        }
        return menu
    }

    private typealias ID = BrowserContextMenu.ID

    private func makeWebView() -> BrowserWebView {
        BrowserWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
    }

    func testLinkMenuOffersNewTabBackgroundTabAndNewWindow() throws {
        let webView = makeWebView()
        let link = menu([ID.openLink, ID.openLinkInNewWindow, ID.downloadLinkedFile, ID.copyLink])
        BrowserContextMenu.customize(link, target: webView, chinese: true)
        XCTAssertEqual(link.items.map(\.title), [ID.openLink, "在新标签页中打开链接", "在后台标签页中打开链接", "在新窗口中打开链接", ID.downloadLinkedFile, ID.copyLink])
        XCTAssertEqual(link.items[2].action, #selector(BrowserWebView.openInBackgroundTab(_:)))
        XCTAssertEqual(link.items[3].action, #selector(BrowserWebView.openInNewWindow(_:)))
        XCTAssertTrue(link.items[2].target === webView)
        XCTAssertTrue(link.items[3].representedObject as? NSMenuItem === link.items[1], "转发的是 WebKit 原来的那一项")
        XCTAssertFalse(link.items.contains { $0.action == #selector(BrowserActions.savePageAs(_:)) }, "链接菜单不加页面级操作")

        BrowserContextMenu.customize(link, target: webView, chinese: true)
        XCTAssertEqual(link.items.count, 6, "重复调用不会再加一遍")

        let english = menu([ID.openLinkInNewWindow])
        BrowserContextMenu.customize(english, target: webView, chinese: false)
        XCTAssertEqual(english.items.map(\.title), ["Open Link in New Tab", "Open Link in Background Tab", "Open Link in New Window"])
    }

    func testImageMediaAndFrameMenus() {
        let webView = makeWebView()
        let image = menu([ID.openImageInNewWindow, ID.downloadImage, ID.copyImage])
        BrowserContextMenu.customize(image, target: webView, chinese: true)
        XCTAssertEqual(Array(image.items.prefix(2).map(\.title)), ["在新标签页中打开图像", "在新窗口中打开图像"])

        let media = menu([ID.openMediaInNewWindow, ID.downloadMedia])
        BrowserContextMenu.customize(media, target: webView, chinese: false)
        XCTAssertEqual(Array(media.items.prefix(2).map(\.title)), ["Open Video in New Tab", "Open Video in New Window"])

        let frame = menu([ID.goBack, ID.goForward, ID.reload, ID.openFrameInNewWindow])
        BrowserContextMenu.customize(frame, target: webView, chinese: true)
        XCTAssertTrue(frame.items.contains { $0.title == "在新标签页中打开框架" })
        XCTAssertTrue(frame.items.contains { $0.title == "在新窗口中打开框架" && $0.action == #selector(BrowserWebView.openInNewWindow(_:)) })
        XCTAssertTrue(frame.items.contains { $0.action == #selector(BrowserActions.showPageSource(_:)) }, "框架空白处也是页面菜单")
    }

    /// 「用 Google 搜索」不再交给系统默认浏览器（会跳出环境和代理），改成在本环境里搜。
    func testSearchWebStaysInsideSession() throws {
        let webView = makeWebView()
        let selection = menu([ID.copy, ID.searchWeb, ID.lookUp], titles: [ID.searchWeb: "用 Google 搜索“hello world”"])
        BrowserContextMenu.customize(selection, target: webView, chinese: true)
        let search = try XCTUnwrap(selection.items.first { $0.identifier?.rawValue == ID.searchWeb })
        XCTAssertEqual(search.action, #selector(BrowserWebView.searchWebForSelection(_:)))
        XCTAssertTrue(search.target === webView)
        XCTAssertEqual(search.representedObject as? String, "hello world")
        XCTAssertEqual(search.title, "用 Google 搜索“hello world”", "标题保留系统的本地化")
        XCTAssertFalse(selection.items.contains { $0.action == #selector(BrowserActions.copyPageURL(_:)) })

        XCTAssertEqual(BrowserContextMenu.quotedText(in: "Search with Google \"a b\""), "a b")
        XCTAssertNil(BrowserContextMenu.quotedText(in: "Search with Google"))
    }

    func testPageMenuGetsSafariPageActionsBeforeInspectElement() throws {
        let page = menu([ID.goBack, ID.goForward, ID.reload, "-", ID.inspectElement])
        BrowserContextMenu.customize(page, target: makeWebView(), chinese: true)
        let actions = page.items.map(\.action)
        XCTAssertEqual(page.items.last?.identifier?.rawValue, ID.inspectElement, "检查元素留在最后")
        let save = try XCTUnwrap(actions.firstIndex(of: #selector(BrowserActions.savePageAs(_:))))
        XCTAssertEqual(page.items[save + 1].action, #selector(BrowserActions.copyPageURL(_:)))
        XCTAssertEqual(page.items[save + 2].action, #selector(BrowserActions.showPageSource(_:)))
        XCTAssertEqual(page.items.filter { $0.action == #selector(BrowserActions.goBack(_:)) }.count, 0, "WebKit 自带后退时不重复加")
        for (lhs, rhs) in zip(page.items, page.items.dropFirst()) {
            XCTAssertFalse(lhs.isSeparatorItem && rhs.isSeparatorItem, "不出现连续两条分隔线")
        }
        XCTAssertEqual(page.items.map(\.title).filter { $0 == "存储页面为…" }.count, 1)

        // WebKit 没给导航项时补上后退 / 前进 / 重新载入。
        let bare = menu([ID.inspectElement])
        BrowserContextMenu.customize(bare, target: makeWebView(), chinese: false)
        XCTAssertEqual(Array(bare.items.prefix(3).map(\.title)), ["Back", "Forward", "Reload Page"])
        XCTAssertEqual(bare.items.last?.identifier?.rawValue, ID.inspectElement)
        BrowserContextMenu.customize(bare, target: makeWebView(), chinese: false)
        XCTAssertEqual(bare.items.filter { $0.title == "Back" }.count, 1, "重复调用不会再加一遍")
    }

    func testEditableMenuGetsNoPageActions() {
        let editable = menu([ID.copy, ID.paste, ID.spellingMenu])
        BrowserContextMenu.customize(editable, target: makeWebView(), chinese: true)
        XCTAssertEqual(editable.items.count, 3)
    }

    /// 「在新窗口 / 后台标签页中打开」先设好打开方式，再执行 WebKit 原来的动作。
    func testForwardedMenuActionSetsOpenMode() throws {
        let webView = makeWebView()
        let recorder = ActionRecorder()
        let link = menu([ID.openLinkInNewWindow])
        link.items[0].target = recorder
        recorder.onFire = { [weak webView] in recorder.states.append((webView?.openNextAsWindow ?? false, webView?.openNextInBackgroundTab ?? false)) }
        BrowserContextMenu.customize(link, target: webView, chinese: true)
        webView.openInNewWindow(link.items[2])
        webView.openInBackgroundTab(link.items[1])
        XCTAssertEqual(recorder.states.count, 2)
        XCTAssertEqual(recorder.states.first?.0, true)
        XCTAssertEqual(recorder.states.last?.1, true)
    }

    // MARK: - 地址栏

    func testPasteAndGoTitle() {
        XCTAssertEqual(AddressTextField.pasteAndGoTitle(for: "https://example.com/a"), "粘贴并前往")
        XCTAssertEqual(AddressTextField.pasteAndGoTitle(for: "  example.com\n"), "粘贴并前往")
        XCTAssertEqual(AddressTextField.pasteAndGoTitle(for: "hello world"), "粘贴并搜索")
        XCTAssertNil(AddressTextField.pasteAndGoTitle(for: "   "))
        XCTAssertNil(AddressTextField.pasteAndGoTitle(for: nil))
    }

    func testPasteAndGoIsInsertedBelowPaste() {
        let field = AddressTextField()
        let menu = NSMenu()
        for selector in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))] {
            menu.addItem(NSMenuItem(title: "\(selector)", action: selector, keyEquivalent: ""))
        }
        AddressTextField.addPasteAndGo(to: menu, clipboard: "example.com", target: field)
        XCTAssertEqual(menu.items[3].title, "粘贴并前往")
        XCTAssertEqual(menu.items[3].action, #selector(AddressTextField.pasteAndGo(_:)))
        XCTAssertTrue(menu.items[3].target === field)
        AddressTextField.addPasteAndGo(to: menu, clipboard: "example.com", target: field)
        XCTAssertEqual(menu.items.count, 5, "不重复加")

        let empty = NSMenu()
        AddressTextField.addPasteAndGo(to: empty, clipboard: nil, target: field)
        XCTAssertTrue(empty.items.isEmpty, "剪贴板没有文字时不加")
    }

    // MARK: - 显示 / 开发

    func testTextZoomStepsAndActualSizeResetsBoth() throws {
        let controller = session.openWindow(url: nil)
        let webView = controller.webView
        try XCTSkipIf(WebViewSPI.textZoomFactor(of: webView) == nil, "本机引擎没有文本缩放能力")
        XCTAssertEqual(WebViewSPI.textZoomFactor(of: webView), 1)
        controller.zoomTextIn(nil)
        XCTAssertEqual(WebViewSPI.textZoomFactor(of: webView) ?? 0, 1.15, accuracy: 0.001)
        controller.zoomTextIn(nil)
        XCTAssertEqual(WebViewSPI.textZoomFactor(of: webView) ?? 0, 1.25, accuracy: 0.001)
        controller.zoomTextOut(nil)
        XCTAssertEqual(WebViewSPI.textZoomFactor(of: webView) ?? 0, 1.15, accuracy: 0.001)
        controller.zoomInPage(nil)
        XCTAssertEqual(webView.pageZoom, 1.15, accuracy: 0.001)
        controller.actualSizePage(nil)
        XCTAssertEqual(webView.pageZoom, 1)
        XCTAssertEqual(WebViewSPI.textZoomFactor(of: webView), 1)
    }

    /// 默认不允许检查网页元素（不向系统登记调试目标）；「开发 → 允许检查网页元素」打开后，
    /// 已开的标签和之后新开的窗口都可检查，再点一次全部关掉。网页检查器接口在本机存在。
    func testInspectableOffByDefaultAndToggleAppliesToAllWindows() {
        let controller = session.openWindow(url: nil)
        XCTAssertFalse(session.inspectable)
        XCTAssertFalse(controller.webView.isInspectable)
        XCTAssertTrue(WebViewSPI.hasInspector(controller.webView))

        let toggle = NSMenuItem(title: "允许检查网页元素", action: #selector(BrowserActions.toggleInspectable(_:)), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(toggle))
        XCTAssertEqual(toggle.state, .off)

        controller.toggleInspectable(toggle)
        XCTAssertTrue(session.inspectable)
        XCTAssertTrue(controller.webView.isInspectable)
        _ = controller.validateMenuItem(toggle)
        XCTAssertEqual(toggle.state, .on)
        let later = session.openWindow(url: nil)
        XCTAssertTrue(later.webView.isInspectable, "之后新开的窗口跟着会话的设置")

        controller.toggleInspectable(toggle)
        XCTAssertFalse(controller.webView.isInspectable)
        XCTAssertFalse(later.webView.isInspectable)
    }

    /// ⌥⌘I / ⌥⌘C 打开检查器时自动允许检查：当前窗口的所有标签一起打开，菜单勾选跟着变。
    func testOpeningInspectorEnablesInspectable() {
        let controller = session.openWindow(url: nil)
        let otherTab = session.openTab(in: controller, url: nil)
        XCTAssertFalse(session.inspectable)

        controller.showWebInspector(nil)

        XCTAssertTrue(session.inspectable)
        XCTAssertTrue(controller.webView.isInspectable)
        XCTAssertTrue(otherTab.webView.isInspectable)
        let toggle = NSMenuItem(title: "允许检查网页元素", action: #selector(BrowserActions.toggleInspectable(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(toggle)
        XCTAssertEqual(toggle.state, .on)
    }

    /// 「开发」菜单：允许检查网页元素和拷贝环境诊断摘要（⌥⇧⌘D）都在；拷贝的是当前窗口的诊断 JSON。
    func testDevelopMenuHasInspectableToggleAndDiagnosticsCopy() throws {
        let develop = try XCTUnwrap(BrowserMenu.make().items.first { $0.title == "开发" }?.submenu)
        let toggle = try XCTUnwrap(develop.items.first { $0.action == #selector(BrowserActions.toggleInspectable(_:)) })
        XCTAssertEqual(toggle.title, "允许检查网页元素")
        let copy = try XCTUnwrap(develop.items.first { $0.action == #selector(BrowserActions.copyDiagnostics(_:)) })
        XCTAssertEqual(copy.title, "拷贝环境诊断摘要")
        XCTAssertEqual(copy.keyEquivalent, "d")
        XCTAssertEqual(copy.keyEquivalentModifierMask, [.command, .option, .shift])
        XCTAssertFalse(copy.isHidden)

        let controller = session.openWindow(url: nil)
        XCTAssertTrue(controller.validateMenuItem(copy), "起始页上也能拷贝诊断")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("safarier.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        controller.diagnosticsPasteboard = pasteboard
        controller.copyDiagnostics(copy)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any])
        XCTAssertNotNil(json["capabilities"])
        XCTAssertEqual((json["window"] as? [String: Any])?["isPopup"] as? Bool, false)
    }

    /// ⇧⌘H：环境没设起始网址时回到起始页。
    func testGoHomeWithoutStartURLShowsStartPage() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/home-test"))
        let controller = session.openWindow(url: url)
        XCTAssertEqual(controller.displayURL, url)
        controller.goHome(nil)
        XCTAssertNil(controller.displayURL)
        XCTAssertEqual(controller.window.title, "起始页面")
        spin(0.5)
        XCTAssertNil(controller.displayURL, "about:blank 载入后仍显示起始页")
        XCTAssertEqual(controller.webView.url?.absoluteString, "about:blank")
    }

    /// 「显示页面源代码」是服务器发来的原文，不是脚本改过的 DOM。
    func testMainResourceDataIsOriginalSourceNotDOM() throws {
        let controller = session.openWindow(url: nil)
        let html = "<!doctype html><!-- original --><p id=x>before</p><script>document.getElementById('x').textContent='after'</script>"
        controller.webView.loadHTMLString(html, baseURL: URL(string: "https://example.invalid/source"))
        spin(1.5)
        let fetched = expectation(description: "source")
        var source: String?
        var dom: String?
        let started = WebViewSPI.mainResourceData(of: controller.webView) { data in
            source = data.map(PageSourceWindowController.decode)
            controller.webView.documentHTML { html in
                dom = html
                fetched.fulfill()
            }
        }
        if case .failure(let failure) = started { throw XCTSkip("本机 WebKit 没有页面原文接口：\(failure)") }
        wait(for: [fetched], timeout: 10)
        XCTAssertEqual(source, html, "原文里还是 before")
        XCTAssertTrue(dom?.contains("after") ?? false, dom ?? "")
        XCTAssertFalse(dom?.contains("before") ?? true, "DOM 已经被脚本改成 after")
    }

    func testPageSourceHighlightingAndFileNames() throws {
        let attributed = PageSourceWindowController.highlighted(#"<a href="x">t</a><!-- c -->"#)
        let tagColor = attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(tagColor, .systemPurple)
        let valueColor = attributed.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor
        XCTAssertEqual(valueColor, .systemBlue)
        let commentColor = attributed.attribute(.foregroundColor, at: (attributed.string as NSString).length - 3, effectiveRange: nil) as? NSColor
        XCTAssertEqual(commentColor, .systemGray)
        XCTAssertEqual(PageSourceWindowController.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café", "不是 UTF-8 时按 Latin-1")

        let url = try XCTUnwrap(URL(string: "https://www.example.com/a"))
        XCTAssertEqual(BrowserWindowController.fileName(title: "a/b:c", url: url, extension: "html"), "a-b-c.html")
        XCTAssertEqual(BrowserWindowController.fileName(title: nil, url: url, extension: "pdf"), "www.example.com.pdf")
    }
}

/// 记录菜单动作被调用时的状态。
@MainActor
final class ActionRecorder: NSObject {
    var states: [(Bool, Bool)] = []
    var onFire: (() -> Void)?

    @objc func fire(_ sender: Any?) { onFire?() }
}
