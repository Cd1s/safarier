import AppKit

/// 网页右键菜单照 Safari 改：WebKit 给的「在新窗口中打开…」改成 Safari 的「在新标签页中打开…」，另加开新窗口 / 后台标签的项；
/// 「用 Google 搜索」改成在本环境的新标签页里搜（WebKit 默认交给系统默认浏览器，会跳出环境和代理）；
/// 页面空白处补上 Safari 的页面级操作。只改菜单，不碰网页。
@MainActor
enum BrowserContextMenu {
    /// WebKit 的菜单项标识（本机 WebKit 20621.3.11 导出的 `WKMenuItemIdentifier*` 常量，值和名字相同）。
    enum ID {
        static let openLink = "WKMenuItemIdentifierOpenLink"
        static let openLinkInNewWindow = "WKMenuItemIdentifierOpenLinkInNewWindow"
        static let downloadLinkedFile = "WKMenuItemIdentifierDownloadLinkedFile"
        static let copyLink = "WKMenuItemIdentifierCopyLink"
        static let openImageInNewWindow = "WKMenuItemIdentifierOpenImageInNewWindow"
        static let downloadImage = "WKMenuItemIdentifierDownloadImage"
        static let copyImage = "WKMenuItemIdentifierCopyImage"
        static let openMediaInNewWindow = "WKMenuItemIdentifierOpenMediaInNewWindow"
        static let downloadMedia = "WKMenuItemIdentifierDownloadMedia"
        static let copyMediaLink = "WKMenuItemIdentifierCopyMediaLink"
        static let openFrameInNewWindow = "WKMenuItemIdentifierOpenFrameInNewWindow"
        static let copy = "WKMenuItemIdentifierCopy"
        static let paste = "WKMenuItemIdentifierPaste"
        static let searchWeb = "WKMenuItemIdentifierSearchWeb"
        static let lookUp = "WKMenuItemIdentifierLookUp"
        static let translate = "WKMenuItemIdentifierTranslate"
        static let spellingMenu = "WKMenuItemIdentifierSpellingMenu"
        static let goBack = "WKMenuItemIdentifierGoBack"
        static let goForward = "WKMenuItemIdentifierGoForward"
        static let reload = "WKMenuItemIdentifierReload"
        static let inspectElement = "WKMenuItemIdentifierInspectElement"
    }

    /// 我们加的项的标识，重复调用时不会加第二遍。
    enum Added {
        static let prefix = "safarier."
        static let backgroundTab = NSUserInterfaceItemIdentifier("safarier.openInBackgroundTab")
        static let newWindow = NSUserInterfaceItemIdentifier("safarier.openInNewWindow")
        static let pageActions = NSUserInterfaceItemIdentifier("safarier.pageActions")
    }

    /// 有这些项说明右键点在链接、图像、媒体、选中文字或输入框上，不是页面空白处。
    static let elementIdentifiers: Set<String> = [
        ID.openLink, ID.openLinkInNewWindow, ID.downloadLinkedFile, ID.copyLink,
        ID.openImageInNewWindow, ID.downloadImage, ID.copyImage,
        ID.openMediaInNewWindow, ID.downloadMedia, ID.copyMediaLink,
        ID.copy, ID.paste, ID.searchWeb, ID.lookUp, ID.translate, ID.spellingMenu,
    ]

    /// `target` 接收新加的「在新窗口 / 后台标签页中打开」和「用 Google 搜索」；页面级操作沿响应链交给当前标签。
    static func customize(_ menu: NSMenu, target: BrowserWebView, chinese: Bool) {
        func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }

        reshape(menu, ID.openLinkInNewWindow, newTab: text("在新标签页中打开链接", "Open Link in New Tab"), target: target, extras: [
            (Added.backgroundTab, text("在后台标签页中打开链接", "Open Link in Background Tab"), #selector(BrowserWebView.openInBackgroundTab(_:))),
            (Added.newWindow, text("在新窗口中打开链接", "Open Link in New Window"), #selector(BrowserWebView.openInNewWindow(_:))),
        ])
        reshape(menu, ID.openImageInNewWindow, newTab: text("在新标签页中打开图像", "Open Image in New Tab"), target: target, extras: [
            (Added.newWindow, text("在新窗口中打开图像", "Open Image in New Window"), #selector(BrowserWebView.openInNewWindow(_:))),
        ])
        reshape(menu, ID.openMediaInNewWindow, newTab: text("在新标签页中打开视频", "Open Video in New Tab"), target: target, extras: [
            (Added.newWindow, text("在新窗口中打开视频", "Open Video in New Window"), #selector(BrowserWebView.openInNewWindow(_:))),
        ])
        reshape(menu, ID.openFrameInNewWindow, newTab: text("在新标签页中打开框架", "Open Frame in New Tab"), target: target, extras: [
            (Added.newWindow, text("在新窗口中打开框架", "Open Frame in New Window"), #selector(BrowserWebView.openInNewWindow(_:))),
        ])

        if let search = item(menu, ID.searchWeb) {
            // 标题（「用 Google 搜索“…”」）由系统本地化，保留；动作改成在本环境里搜。
            search.representedObject = quotedText(in: search.title)
            search.target = target
            search.action = #selector(BrowserWebView.searchWebForSelection(_:))
        }

        addPageActions(to: menu, text: text)
    }

    /// 原项改名为「在新标签页中打开…」，紧跟着插入 `extras`；extras 转发原项的动作（先设好打开方式）。
    private static func reshape(
        _ menu: NSMenu, _ identifier: String, newTab title: String, target: BrowserWebView,
        extras: [(NSUserInterfaceItemIdentifier, String, Selector)]
    ) {
        guard let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == identifier }) else { return }
        let original = menu.items[index]
        original.title = title
        var position = index + 1
        for (id, title, action) in extras {
            if position < menu.items.count, menu.items[position].identifier == id { position += 1; continue }
            let extra = NSMenuItem(title: title, action: action, keyEquivalent: "")
            extra.identifier = id
            extra.target = target
            extra.representedObject = original
            menu.insertItem(extra, at: position)
            position += 1
        }
    }

    /// 页面空白处（不是链接、图像、选中文字、输入框）：补齐后退 / 前进 / 重新载入，再加存储、拷贝地址、源代码。
    private static func addPageActions(to menu: NSMenu, text: (String, String) -> String) {
        let identifiers = Set(menu.items.compactMap { $0.identifier?.rawValue })
        guard identifiers.isDisjoint(with: elementIdentifiers),
              !identifiers.contains(Added.pageActions.rawValue) else { return }

        var top: [NSMenuItem] = []
        if !identifiers.contains(ID.goBack) { top.append(action(text("后退", "Back"), #selector(BrowserActions.goBack(_:)))) }
        if !identifiers.contains(ID.goForward) { top.append(action(text("前进", "Forward"), #selector(BrowserActions.goForward(_:)))) }
        if !identifiers.contains(ID.reload) { top.append(action(text("重新载入页面", "Reload Page"), #selector(BrowserActions.reloadPage(_:)))) }
        // 补的导航项放在 WebKit 自带导航项后面（没有就放最上面）。
        let navigationEnd = menu.items.lastIndex { [ID.goBack, ID.goForward, ID.reload].contains($0.identifier?.rawValue ?? "") }.map { $0 + 1 } ?? 0
        for (offset, entry) in top.enumerated() { menu.insertItem(entry, at: navigationEnd + offset) }

        let save = action(text("存储页面为…", "Save Page As…"), #selector(BrowserActions.savePageAs(_:)))
        save.identifier = Added.pageActions
        let page = [
            save,
            action(text("拷贝页面地址", "Copy Page Address"), #selector(BrowserActions.copyPageURL(_:))),
            action(text("显示页面源代码", "Show Page Source"), #selector(BrowserActions.showPageSource(_:))),
        ]
        // 「检查元素」留在最后，和 Safari 一样；前后用分隔线隔开（已有的不重复加）。
        var position = menu.items.firstIndex { $0.identifier?.rawValue == ID.inspectElement } ?? menu.items.count
        if position > 0, !menu.items[position - 1].isSeparatorItem {
            menu.insertItem(.separator(), at: position)
            position += 1
        }
        for entry in page {
            menu.insertItem(entry, at: position)
            position += 1
        }
        if position < menu.items.count, !menu.items[position].isSeparatorItem {
            menu.insertItem(.separator(), at: position)
        }
    }

    private static func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: selector, keyEquivalent: "")
    }

    private static func item(_ menu: NSMenu, _ identifier: String) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == identifier }
    }

    /// 「用 Google 搜索“hello world”」→ `hello world`；取不到时返回 nil。系统会截断很长的选中文字，所以只作备用。
    static func quotedText(in title: String) -> String? {
        let pairs: [(Character, Character)] = [("“", "”"), ("\"", "\""), ("「", "」")]
        for (open, close) in pairs {
            guard let start = title.firstIndex(of: open), let end = title.lastIndex(of: close), start < end else { continue }
            let value = String(title[title.index(after: start)..<end])
            if !value.isEmpty { return value }
        }
        return nil
    }
}
