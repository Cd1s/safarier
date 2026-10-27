import AppKit

/// 浏览窗口的菜单栏，结构和快捷键照 Safari。动作沿响应链发给当前标签（BrowserWindowController），
/// 没有窗口时由 BrowserSession（应用代理）接住新建窗口 / 标签 / 恢复关闭的标签。
@MainActor
enum BrowserMenu {
    static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    static func make() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Safarier", [
            item("关于 Safarier", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("隐藏 Safarier", #selector(NSApplication.hide(_:)), "h"),
            item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("全部显示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("退出 Safarier", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("文件", [
            item("新建窗口", #selector(BrowserActions.newWindow(_:)), "n"),
            item("新建标签页", #selector(BrowserActions.newTab(_:)), "t"),
            item("重新打开上次关闭的标签页", #selector(BrowserActions.reopenClosedTab(_:)), "t", [.command, .shift]),
            item("打开位置…", #selector(BrowserActions.focusLocation(_:)), "l"),
            .separator(),
            item("关闭标签页", #selector(BrowserActions.closeTab(_:)), "w"),
            item("关闭其他标签页", #selector(BrowserActions.closeOtherTabs(_:)), "w", [.command, .option]),
            item("关闭窗口", #selector(BrowserActions.closeWindow(_:)), "w", [.command, .shift]),
            .separator(),
            item("存储为…", #selector(BrowserActions.savePageAs(_:)), "s"),
            item("导出为 PDF…", #selector(BrowserActions.exportPDF(_:))),
            .separator(),
            item("打印…", #selector(BrowserActions.printPage(_:)), "p"),
        ]))

        main.addItem(submenu("编辑", [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("查找…", #selector(BrowserActions.showFind(_:)), "f"),
            item("查找下一个", #selector(BrowserActions.findNextMatch(_:)), "g"),
            item("查找上一个", #selector(BrowserActions.findPreviousMatch(_:)), "g", [.command, .shift]),
            item("使用所选内容查找", #selector(BrowserActions.useSelectionForFind(_:)), "e"),
        ]))

        main.addItem(submenu("显示", [
            item("显示所有标签页", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]),
            item("显示标签页栏", #selector(NSWindow.toggleTabBar(_:))),
            .separator(),
            item("停止", #selector(BrowserActions.stopLoading(_:)), "."),
            item("重新载入页面", #selector(BrowserActions.reloadPage(_:)), "r"),
            item("从原始位置重新载入", #selector(BrowserActions.reloadFromOrigin(_:)), "r", [.command, .option]),
            hidden(item("从原始位置重新载入", #selector(BrowserActions.reloadFromOrigin(_:)), "r", [.command, .shift])),
            .separator(),
            item("实际大小", #selector(BrowserActions.actualSizePage(_:)), "0"),
            item("放大", #selector(BrowserActions.zoomInPage(_:)), "+"),
            hidden(item("放大", #selector(BrowserActions.zoomInPage(_:)), "=")),
            item("缩小", #selector(BrowserActions.zoomOutPage(_:)), "-"),
            item("放大文本", #selector(BrowserActions.zoomTextIn(_:)), "+", [.command, .option]),
            hidden(item("放大文本", #selector(BrowserActions.zoomTextIn(_:)), "=", [.command, .option])),
            item("缩小文本", #selector(BrowserActions.zoomTextOut(_:)), "-", [.command, .option]),
            .separator(),
            item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu("历史记录", [
            item("后退", #selector(BrowserActions.goBack(_:)), "["),
            hidden(item("后退", #selector(BrowserActions.goBack(_:)), leftArrow)),
            item("前进", #selector(BrowserActions.goForward(_:)), "]"),
            hidden(item("前进", #selector(BrowserActions.goForward(_:)), rightArrow)),
            item("起始页面", #selector(BrowserActions.goHome(_:)), "h", [.command, .shift]),
            .separator(),
            item("重新打开上次关闭的标签页", #selector(BrowserActions.reopenClosedTab(_:))),
        ]))

        main.addItem(submenu("开发", [
            item("显示网页检查器", #selector(BrowserActions.showWebInspector(_:)), "i", [.command, .option]),
            item("显示 JavaScript 控制台", #selector(BrowserActions.showJavaScriptConsole(_:)), "c", [.command, .option]),
            item("显示页面源代码", #selector(BrowserActions.showPageSource(_:)), "u", [.command, .option]),
            .separator(),
            item("允许检查网页元素", #selector(BrowserActions.toggleInspectable(_:))),
        ]))

        let windowMenu = NSMenu(title: "窗口")
        var windowItems: [NSMenuItem] = [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("缩放", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("循环显示窗口", #selector(BrowserActions.cycleWindowsForward(_:)), "`"),
            // 中文输入法下 ⌘` 打出来是 ⌘·。
            hidden(item("循环显示窗口", #selector(BrowserActions.cycleWindowsForward(_:)), "·")),
            hidden(item("反向循环显示窗口", #selector(BrowserActions.cycleWindowsBackward(_:)), "`", [.command, .shift])),
            hidden(item("反向循环显示窗口", #selector(BrowserActions.cycleWindowsBackward(_:)), "~", [.command, .shift])),
            hidden(item("反向循环显示窗口", #selector(BrowserActions.cycleWindowsBackward(_:)), "·", [.command, .shift])),
            hidden(item("反向循环显示窗口", #selector(BrowserActions.cycleWindowsBackward(_:)), "～", [.command, .shift])),
            .separator(),
            item("显示上一个标签页", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]),
            // ⌃⇧⇥：按住 ⇧ 时 Tab 键的字符是 backtab（U+0019）。
            hidden(item("显示上一个标签页", #selector(NSWindow.selectPreviousTab(_:)), "\u{19}", [.control, .shift])),
            hidden(item("显示上一个标签页", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift])),
            item("显示下一个标签页", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]),
            hidden(item("显示下一个标签页", #selector(NSWindow.selectNextTab(_:)), "\t", .control)),
            item("复制标签页", #selector(BrowserActions.duplicateTab(_:))),
            item("将标签页移到新窗口", #selector(NSWindow.moveTabToNewWindow(_:))),
            item("合并所有窗口", #selector(NSWindow.mergeAllWindows(_:))),
            .separator(),
            item("显示下载项", #selector(BrowserActions.toggleDownloads(_:)), "l", [.command, .option]),
            .separator(),
            item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))),
        ]
        // ⌘1…⌘8 切到当前窗口第 1…8 个标签，⌘9 切到最后一个，和 Safari 一样。
        for index in 1...9 {
            let entry = hidden(item(index == 9 ? "显示最后一个标签页" : "显示第 \(index) 个标签页", #selector(BrowserActions.selectTabByNumber(_:)), "\(index)"))
            entry.tag = index
            windowItems.append(entry)
        }
        windowItems.forEach(windowMenu.addItem)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    /// 同一动作的备用快捷键（美式键盘上 ⌘+ 实际按的是 ⌘=、中文输入法下的 ⌘· 等）：菜单里不显示，快捷键照样生效（Safari 也是这样）。
    private static func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }
}

/// 菜单动作的 selector 声明（实现在 BrowserWindowController；没有窗口时 BrowserSession 实现其中几个）。
/// 都是可选的：响应链上没人实现的动作，菜单项自动变灰。
@MainActor @objc protocol BrowserActions {
    @objc optional func newWindow(_ sender: Any?)
    @objc optional func newTab(_ sender: Any?)
    @objc optional func reopenClosedTab(_ sender: Any?)
    @objc optional func focusLocation(_ sender: Any?)
    @objc optional func closeTab(_ sender: Any?)
    @objc optional func closeOtherTabs(_ sender: Any?)
    @objc optional func closeWindow(_ sender: Any?)
    @objc optional func savePageAs(_ sender: Any?)
    @objc optional func exportPDF(_ sender: Any?)
    @objc optional func printPage(_ sender: Any?)
    @objc optional func showFind(_ sender: Any?)
    @objc optional func findNextMatch(_ sender: Any?)
    @objc optional func findPreviousMatch(_ sender: Any?)
    @objc optional func useSelectionForFind(_ sender: Any?)
    @objc optional func stopLoading(_ sender: Any?)
    @objc optional func reloadPage(_ sender: Any?)
    @objc optional func reloadFromOrigin(_ sender: Any?)
    @objc optional func actualSizePage(_ sender: Any?)
    @objc optional func zoomInPage(_ sender: Any?)
    @objc optional func zoomOutPage(_ sender: Any?)
    @objc optional func zoomTextIn(_ sender: Any?)
    @objc optional func zoomTextOut(_ sender: Any?)
    @objc optional func goBack(_ sender: Any?)
    @objc optional func goForward(_ sender: Any?)
    @objc optional func goHome(_ sender: Any?)
    @objc optional func copyPageURL(_ sender: Any?)
    @objc optional func showWebInspector(_ sender: Any?)
    @objc optional func showJavaScriptConsole(_ sender: Any?)
    @objc optional func showPageSource(_ sender: Any?)
    @objc optional func toggleInspectable(_ sender: Any?)
    @objc optional func cycleWindowsForward(_ sender: Any?)
    @objc optional func cycleWindowsBackward(_ sender: Any?)
    @objc optional func duplicateTab(_ sender: Any?)
    @objc optional func selectTabByNumber(_ sender: Any?)
    @objc optional func toggleDownloads(_ sender: Any?)
}
