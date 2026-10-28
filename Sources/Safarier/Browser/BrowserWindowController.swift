import AppKit
import WebKit
import SafarierCore
import SafarierWebKit

/// 一个标签页。用 macOS 原生窗口标签（每个标签是一个 NSWindow），所以 ⌘T、拖出成新窗口、合并窗口、
/// 标签概览都是系统现成的；只有一个标签时不显示标签栏，和 Safari 的「分离」布局一样。
@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation,
    NSMenuItemValidation, NSSharingServicePickerToolbarItemDelegate, WKNavigationDelegate, WKUIDelegate, BrowserActions {
    /// 统一工具栏（标题栏 + 工具栏）的高度。真 Safari 单标签窗口实测 outerHeight − innerHeight = 52。
    static let chromeHeight: CGFloat = 52
    /// Safari 的缩放档位。
    private static let zoomLevels: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    unowned let session: BrowserSession
    let window: NSWindow
    let webView: BrowserWebView
    /// 网页打开的视图（window.open、target=_blank、右键新标签 / 新窗口）：由 WebKit 载入，不显示起始页、不抢地址栏焦点。
    let isPopup: Bool
    private let addressBar: AddressBar
    private let findBar = FindBar()
    private let startPage: StartPageView
    private let content = NSStackView()
    private var observations: [NSKeyValueObservation] = []
    private var downloadsPopover: NSPopover?
    /// 当前显示的是我们自己的出错页时，记下原本要打开的网址（重新载入时重试它）。
    private(set) var failedURL: URL?
    /// 主框架这次导航要去的网址（导航决策时记下，服务器重定向后更新，提交后清空）。
    /// 没提交的导航失败时 webView.url 还是之前那个正常显示的页面，出错页要挂在这个网址上。
    private(set) var pendingNavigationURL: URL?
    /// 最近一次提交的网址：用来分辨重定向后 webView.url 是新地址还是旧页面。
    private var committedURL: URL?
    /// 正在载入我们自己的出错页：这次载入再失败就不再生成出错页，避免来回循环。
    private(set) var isLoadingErrorPage = false
    /// 新标签 / 新窗口要在成为 key window 之后再把焦点放进地址栏，早了会被系统重置。
    private(set) var wantsAddressFocus = false
    /// ⇧⌘H 回到起始页（环境没设起始网址时）：载入 about:blank 并显示起始页，直到导航到别的网址。
    private var showingHome = false
    /// 在起始页上打开网页检查器时自动隐藏起始页（否则停靠在 webView 内的检查器会被起始页盖住）。
    private var inspectorDismissedStartPage = false
    /// 脱敏的导航诊断（「开发 → 拷贝环境诊断摘要」用）。只有状态码、次数和错误码，不记网址、Cookie、账号。
    private(set) var navigationDiagnostics = NavigationDiagnostics()

    struct NavigationDiagnostics: Equatable {
        /// 最近一次主框架响应的 HTTP 状态码；新导航开始时清空，非 HTTP 响应（about:、出错页）没有。
        var lastMainFrameStatusCode: Int?
        /// 当前（最近一次）主框架导航经历的服务器重定向次数。
        var redirectCount = 0
        /// 最近一次显示了出错页的加载错误。
        var lastErrorDomain: String?
        var lastErrorCode: Int?
    }

    private enum Item {
        static let profile = NSToolbarItem.Identifier("profile")
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let address = NSToolbarItem.Identifier("address")
        static let share = NSToolbarItem.Identifier("share")
        static let downloads = NSToolbarItem.Identifier("downloads")
        static let newTab = NSToolbarItem.Identifier("newTab")
        static let tabOverview = NSToolbarItem.Identifier("tabOverview")
    }

    init(session: BrowserSession, webView: BrowserWebView, contentSize: NSSize, isPopup: Bool = false) {
        self.session = session
        self.webView = webView
        self.isPopup = isPopup
        addressBar = AddressBar(isPrivate: session.isPrivate)
        startPage = StartPageView(profile: session.profile, accent: session.accent, details: session.startPageDetails)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildWindow(contentSize: contentSize)
        observe()
    }

    // MARK: - 布局

    private func buildWindow(contentSize: NSSize) {
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "safarier.\(session.profile.id.uuidString)"
        window.tabbingMode = .automatic
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = "起始页面"
        window.minSize = NSSize(width: 500, height: 300)

        let toolbar = NSToolbar(identifier: "SafarierBrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Item.address]
        window.toolbar = toolbar

        webView.navigationDelegate = self
        webView.uiDelegate = self

        findBar.isHidden = true
        findBar.onFind = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFind() }

        webView.onSearchWeb = { [weak self] url in
            guard let self else { return }
            self.session.openTab(in: self, url: url)
        }

        addressBar.onSubmit = { [weak self] text in self?.navigate(to: text) }
        addressBar.onReload = { [weak self] in self?.reloadPage(nil) }
        addressBar.onStop = { [weak self] in self?.webView.stopLoading() }
        // Esc 取消编辑：在打开的网页上时把焦点还给网页。
        addressBar.onCancel = { [weak self] in
            guard let self, self.displayURL != nil else { return }
            self.window.makeFirstResponder(self.webView)
        }

        content.orientation = .vertical
        content.spacing = 0
        content.addArrangedSubview(findBar)
        content.addArrangedSubview(webView)
        for view in [findBar, webView] as [NSView] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        content.translatesAutoresizingMaskIntoConstraints = false
        startPage.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        container.addSubview(startPage)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            startPage.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            startPage.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            startPage.topAnchor.constraint(equalTo: webView.topAnchor),
            startPage.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
        window.contentView = container
        window.setContentSize(contentSize)
    }

    private func observe() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateState() } },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTitle() } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateState() } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateState() } },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateState() } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.window.toolbar?.validateVisibleItems() } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.window.toolbar?.validateVisibleItems() } },
        ]
    }

    /// 起始页是不是正显示着（测试和诊断用）。
    var isShowingStartPage: Bool { !startPage.isHidden }

    /// 地址栏、标题、菜单用的当前网址：起始页（新标签或 ⇧⌘H）时为 nil。
    var displayURL: URL? {
        showingHome ? nil : webView.url
    }

    func updateState() {
        // 后退 / 前进回到 ⇧⌘H 留下的 about:blank 时也显示起始页；网页打开的空白弹窗（isPopup）或已打开检查器的空白页不算。
        if let url = webView.url {
            if url.absoluteString != "about:blank" { inspectorDismissedStartPage = false }
            showingHome = !isPopup && !inspectorDismissedStartPage && url.absoluteString == "about:blank"
        }
        let url = displayURL
        startPage.isHidden = isPopup || inspectorDismissedStartPage || url != nil || (webView.isLoading && !showingHome)
        addressBar.update(url: url, isLoading: webView.isLoading && !showingHome, progress: webView.estimatedProgress, secure: webView.hasOnlySecureContent)
        updateTitle()
    }

    /// 标签上显示网页标题；没有标题时显示域名，和 Safari 一样。
    private func updateTitle() {
        if showingHome {
            window.title = "起始页面"
        } else if let title = webView.title, !title.isEmpty {
            window.title = title
        } else if let host = webView.url?.host {
            window.title = host
        } else {
            window.title = webView.url == nil ? "起始页面" : (webView.url?.absoluteString ?? "")
        }
    }

    // MARK: - 打开网页

    func load(_ url: URL?) {
        if let url {
            webView.load(URLRequest(url: url))
        } else {
            updateState()
            wantsAddressFocus = true
            if window.isKeyWindow { focusAddressIfWanted() }
        }
    }

    private func navigate(to text: String) {
        guard let url = AddressInput.url(for: text) else { return }
        open(url)
    }

    private func open(_ url: URL) {
        failedURL = nil
        showingHome = false
        webView.load(URLRequest(url: url))
        window.makeFirstResponder(webView)
    }

    private func find(_ text: String, backwards: Bool) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            self?.findBar.show(found: result.matchFound)
        }
    }

    private func hideFind() {
        findBar.isHidden = true
        window.makeFirstResponder(webView)
    }

    func downloadsChanged() {
        guard let toolbar = window.toolbar else { return }
        if !toolbar.items.contains(where: { $0.itemIdentifier == Item.downloads }),
           let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Item.newTab }) {
            toolbar.insertItem(withItemIdentifier: Item.downloads, at: index)
        }
        if let popover = downloadsPopover, popover.isShown {
            popover.contentViewController = session.downloads.makePopoverContent()
        }
    }

    // MARK: - 菜单 / 工具栏动作

    /// 同一窗口里的标签，按标签栏顺序。
    var tabs: [NSWindow] { window.tabGroup?.windows ?? [window] }

    @objc func newWindow(_ sender: Any?) { session.openWindow(url: nil) }
    @objc func newTab(_ sender: Any?) { session.openTab(in: self, url: nil) }
    /// 标签栏右侧的 "+"。
    @objc func newWindowForTab(_ sender: Any?) { session.openTab(in: self, url: nil) }
    @objc func reopenClosedTab(_ sender: Any?) { session.reopenClosedTab(in: self) }
    @objc func focusLocation(_ sender: Any?) { addressBar.focus() }
    @objc func closeTab(_ sender: Any?) { window.performClose(sender) }
    /// ⌥⌘W：关掉同一窗口里的其它标签。
    @objc func closeOtherTabs(_ sender: Any?) {
        for tab in tabs where tab !== window { tab.performClose(sender) }
    }
    @objc func closeWindow(_ sender: Any?) {
        for tab in window.tabbedWindows ?? [window] { tab.performClose(sender) }
    }

    /// ⌘S：把当前页面（DOM）存成 .html。
    @objc func savePageAs(_ sender: Any?) {
        guard let url = displayURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = Self.fileName(title: webView.title, url: url, extension: "html")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.webView.documentHTML { [weak self] html in
                guard let html else { return NSSound.beep() }
                do { try Data(html.utf8).write(to: destination, options: .atomic) } catch { self?.presentError(error) }
            }
        }
    }

    /// 导出为 PDF…：整页（不只是可见区域）。
    @objc func exportPDF(_ sender: Any?) {
        guard let url = displayURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Self.fileName(title: webView.title, url: url, extension: "pdf")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.webView.createPDF { [weak self] result in
                do { try result.get().write(to: destination, options: .atomic) } catch { self?.presentError(error) }
            }
        }
    }

    /// 网页标题（没有就用域名）做文件名，去掉文件名里不能用的字符。
    static func fileName(title: String?, url: URL, extension ext: String) -> String {
        let base = (title?.isEmpty == false ? title! : (url.host ?? "页面"))
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base.isEmpty ? "页面" : String(base.prefix(120))).\(ext)"
    }

    private func presentError(_ error: Error) {
        NSAlert(error: error).beginSheetModal(for: window)
    }

    @objc func printPage(_ sender: Any?) {
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func loadExtension(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "加载扩展"
        panel.message = "选择包含 manifest.json 的扩展目录或 .appex 扩展包"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let record = try self.session.workspace.importExtension(from: url)
                try self.session.workspace.enableExtension(record.id, for: self.session.profile.id)
                Task { @MainActor in
                    if let runtime = self.session.extensionRuntime {
                        await runtime.load(record)
                        self.presentExtensionMessage("已加载扩展：\(record.name)")
                    } else {
                        self.presentExtensionMessage("已安装扩展：\(record.name)；当前 WebKit 不提供扩展运行时，重启环境后仍会保留。")
                    }
                }
            } catch {
                self.presentExtensionMessage("扩展加载失败：\(error.localizedDescription)")
            }
        }
    }

    @objc func manageExtensions(_ sender: Any?) {
        do {
            let records = try session.workspace.extensionRecords()
            let enabled = Set(try session.workspace.enabledExtensions(for: session.profile.id).map(\.id))
            let text = records.isEmpty ? "当前没有已安装扩展。" : records.map { record in
                "\(record.name) \(record.version) — \(enabled.contains(record.id) ? "已启用" : "未启用")"
            }.joined(separator: "\n")
            presentExtensionMessage(text)
        } catch {
            presentExtensionMessage("无法读取扩展列表：\(error.localizedDescription)")
        }
    }

    private func presentExtensionMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Safarier 扩展"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
    @objc func showFind(_ sender: Any?) {
        findBar.isHidden = false
        window.makeFirstResponder(findBar.searchField)
    }
    @objc func findNextMatch(_ sender: Any?) { findBar.isHidden ? showFind(sender) : findBar.findNext() }
    @objc func findPreviousMatch(_ sender: Any?) { findBar.isHidden ? showFind(sender) : findBar.findPrevious() }
    /// ⌘E：用页面里选中的文字查找（也放进系统的查找剪贴板，和其它 App 共用）。
    @objc func useSelectionForFind(_ sender: Any?) {
        webView.selectedText { [weak self] text in
            guard let self, let text, !text.isEmpty else { return NSSound.beep() }
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.findBar.searchField.stringValue = text
            self.findBar.isHidden = false
            self.find(text, backwards: false)
        }
    }
    @objc func stopLoading(_ sender: Any?) { webView.stopLoading() }
    @objc func reloadPage(_ sender: Any?) {
        if let failedURL {
            self.failedURL = nil
            webView.load(URLRequest(url: failedURL))
        } else {
            webView.reload()
        }
    }
    /// ⌥⌘R：不用缓存，从服务器重新载入。
    @objc func reloadFromOrigin(_ sender: Any?) {
        if let failedURL {
            self.failedURL = nil
            webView.load(URLRequest(url: failedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        } else {
            webView.reloadFromOrigin()
        }
    }
    /// ⌘0：页面缩放和文本缩放都回到 100%。
    @objc func actualSizePage(_ sender: Any?) {
        webView.pageZoom = 1
        WebViewSPI.setTextZoomFactor(1, on: webView)
    }
    @objc func zoomInPage(_ sender: Any?) {
        webView.pageZoom = Self.zoomLevels.first { $0 > webView.pageZoom + 0.001 } ?? webView.pageZoom
    }
    @objc func zoomOutPage(_ sender: Any?) {
        webView.pageZoom = Self.zoomLevels.last { $0 < webView.pageZoom - 0.001 } ?? webView.pageZoom
    }
    /// ⌥⌘+ / ⌥⌘-：只放大缩小文字（原生引擎桥接），档位和页面缩放一样。
    @objc func zoomTextIn(_ sender: Any?) { stepTextZoom(up: true) }
    @objc func zoomTextOut(_ sender: Any?) { stepTextZoom(up: false) }

    private func nextTextZoom(up: Bool) -> Double? {
        guard let current = WebViewSPI.textZoomFactor(of: webView) else { return nil }
        let levels = Self.zoomLevels.map(Double.init)
        return up ? levels.first { $0 > current + 0.001 } : levels.last { $0 < current - 0.001 }
    }

    private func stepTextZoom(up: Bool) {
        guard let next = nextTextZoom(up: up) else { return NSSound.beep() }
        WebViewSPI.setTextZoomFactor(next, on: webView)
    }

    @objc func goBack(_ sender: Any?) {
        failedURL = nil
        webView.goBack()
    }
    @objc func goForward(_ sender: Any?) {
        failedURL = nil
        webView.goForward()
    }
    /// ⇧⌘H：打开环境的起始网址；没设时回到起始页。
    @objc func goHome(_ sender: Any?) {
        if let start = session.profile.startURL {
            open(start)
        } else {
            failedURL = nil
            inspectorDismissedStartPage = false
            showingHome = true
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            updateState()
        }
    }
    @objc func copyPageURL(_ sender: Any?) {
        guard let url = displayURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }
    @objc func toggleInspectable(_ sender: Any?) { session.toggleInspectable(sender) }

    // MARK: 开发

    /// ⌥⌘I / ⌥⌘C：打开网页检查器 / JavaScript 控制台（原生引擎桥接）。
    @objc func showWebInspector(_ sender: Any?) { openInspector(.show) }
    @objc func showJavaScriptConsole(_ sender: Any?) { openInspector(.showConsole) }

    private func openInspector(_ action: WebViewSPI.InspectorAction) {
        // inspectable 默认关闭：打开检查器时自动打开（所有标签一起），菜单里的勾选也跟着变。
        if !session.inspectable { session.setInspectable(true) }
        webView.isInspectable = true
        WebViewSPI.setDeveloperExtrasEnabled(true, on: webView.configuration.preferences)
        if isShowingStartPage {
            inspectorDismissedStartPage = true
            showingHome = false
            startPage.isHidden = true
            if webView.url == nil {
                webView.load(URLRequest(url: URL(string: "about:blank")!))
            }
        }
        if case .failure(let failure) = WebViewSPI.inspector(action, on: webView) {
            FileHandle.standardError.write(Data("[inspector] \(action.rawValue) 失败：\(failure)\n".utf8))
            NSSound.beep()
        }
    }

    /// 诊断摘要写到哪个剪贴板（测试换成私有剪贴板，不碰用户的系统剪贴板）。
    var diagnosticsPasteboard: NSPasteboard = .general

    /// ⌥⇧⌘D：把当前窗口的脱敏诊断摘要（JSON）拷到剪贴板，方便贴进问题报告。
    @objc func copyDiagnostics(_ sender: Any?) {
        let pasteboard = diagnosticsPasteboard
        pasteboard.clearContents()
        pasteboard.setString(sanitizedDiagnosticsSummary(), forType: .string)
    }

    /// ⌥⌘U：显示服务器发来的页面原文（取不到时退回当前 DOM）。
    @objc func showPageSource(_ sender: Any?) {
        guard let url = displayURL else { return }
        let title = webView.title?.isEmpty == false ? webView.title! : (url.host ?? url.absoluteString)
        let started = WebViewSPI.mainResourceData(of: webView) { [weak self] data in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.session.showSource(PageSourceWindowController.decode(data), title: title, url: url, relativeTo: self.window)
            } else {
                self.showSourceFromDOM(title: title, url: url)
            }
        }
        if case .failure = started { showSourceFromDOM(title: title, url: url) }
    }

    private func showSourceFromDOM(title: String, url: URL) {
        webView.documentHTML { [weak self] html in
            guard let self, let html else { return NSSound.beep() }
            self.session.showSource(html, title: title, url: url, relativeTo: self.window)
        }
    }

    // MARK: 窗口与标签

    @objc func cycleWindowsForward(_ sender: Any?) { session.cycleWindows(forward: true) }
    @objc func cycleWindowsBackward(_ sender: Any?) { session.cycleWindows(forward: false) }

    /// 复制标签页：在当前窗口新开一个标签，打开同一个网址。
    @objc func duplicateTab(_ sender: Any?) { session.openTab(in: self, url: displayURL) }

    /// ⌘1…⌘8 切到第 1…8 个标签，⌘9 切到最后一个（菜单项的 tag 是数字）。
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag else { return }
        selectTab(number: number)
    }

    func selectTab(number: Int) {
        let tabs = tabs
        guard let target = Self.tab(number: number, in: tabs) else { return }
        window.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    static func tab<T>(number: Int, in tabs: [T]) -> T? {
        if number >= 9 { return tabs.last }
        return number >= 1 && number <= tabs.count ? tabs[number - 1] : nil
    }

    @objc private func showTabOverview(_ sender: Any?) { window.toggleTabOverview(sender) }

    /// ⌥⌘L：显示 / 收起下载列表。
    @objc func toggleDownloads(_ sender: Any?) {
        if let popover = downloadsPopover, popover.isShown {
            popover.performClose(sender)
        } else {
            showDownloads(sender)
        }
    }

    @objc private func showDownloads(_ sender: Any?) {
        downloadsChanged()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = session.downloads.makePopoverContent()
        if let view = sender as? NSView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Item.downloads }) {
            popover.show(relativeTo: item)
        } else {
            popover.show(relativeTo: addressBar.bounds, of: addressBar, preferredEdge: .minY)
        }
        downloadsPopover = popover
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return webView.canGoBack && !arrowKeyWhileEditing(item)
        case #selector(goForward(_:)): return webView.canGoForward && !arrowKeyWhileEditing(item)
        case #selector(stopLoading(_:)): return webView.isLoading
        case #selector(actualSizePage(_:)): return webView.pageZoom != 1 || (WebViewSPI.textZoomFactor(of: webView) ?? 1) != 1
        case #selector(zoomInPage(_:)): return displayURL != nil && webView.pageZoom < (Self.zoomLevels.last ?? 3) - 0.001
        case #selector(zoomOutPage(_:)): return displayURL != nil && webView.pageZoom > (Self.zoomLevels.first ?? 0.5) + 0.001
        case #selector(zoomTextIn(_:)): return displayURL != nil && nextTextZoom(up: true) != nil
        case #selector(zoomTextOut(_:)): return displayURL != nil && nextTextZoom(up: false) != nil
        case #selector(printPage(_:)), #selector(reloadPage(_:)), #selector(reloadFromOrigin(_:)), #selector(savePageAs(_:)),
             #selector(exportPDF(_:)), #selector(copyPageURL(_:)), #selector(showPageSource(_:)), #selector(useSelectionForFind(_:)),
             #selector(showFind(_:)), #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)), #selector(duplicateTab(_:)):
            return displayURL != nil
        case #selector(goHome(_:)): return displayURL != nil || session.profile.startURL != nil
        case #selector(closeOtherTabs(_:)): return tabs.count > 1
        case #selector(reopenClosedTab(_:)): return !session.closedTabURLs.isEmpty
        case #selector(selectTabByNumber(_:)): return Self.tab(number: item.tag, in: tabs) != nil
        case #selector(showWebInspector(_:)), #selector(showJavaScriptConsole(_:)): return WebViewSPI.hasInspector(webView)
        case #selector(toggleInspectable(_:)): return session.validateMenuItem(item)
        default: return true
        }
    }

    /// ⌘← / ⌘→ 在地址栏、查找栏里是移到行首 / 行尾：这时让菜单不接，按键交给文本框。
    private func arrowKeyWhileEditing(_ item: NSMenuItem) -> Bool {
        [BrowserMenu.leftArrow, BrowserMenu.rightArrow].contains(item.keyEquivalent) && window.firstResponder is NSTextView
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.back: return webView.canGoBack
        case Item.forward: return webView.canGoForward
        default: return true
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.profile, Item.back, Item.forward, .flexibleSpace, Item.address, .flexibleSpace, Item.share, Item.newTab, Item.tabOverview]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Item.downloads]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Item.profile:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = ProfileBadge(profile: session.profile, accent: session.accent, isPrivate: session.isPrivate)
            item.label = "环境"
            item.toolTip = session.startPageDetails.joined(separator: "\n")
            return item
        case Item.back:
            return button(identifier, symbol: "chevron.left", label: "后退", action: #selector(goBack(_:)))
        case Item.forward:
            return button(identifier, symbol: "chevron.right", label: "前进", action: #selector(goForward(_:)))
        case Item.address:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = addressBar
            item.label = "地址"
            item.visibilityPriority = .high
            return item
        case Item.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.delegate = self
            item.label = "共享"
            item.toolTip = "共享"
            return item
        case Item.downloads:
            return button(identifier, symbol: "arrow.down.circle", label: "下载", action: #selector(showDownloads(_:)))
        case Item.newTab:
            return button(identifier, symbol: "plus", label: "新建标签页", action: #selector(newTab(_:)))
        case Item.tabOverview:
            return button(identifier, symbol: "square.on.square", label: "显示所有标签页", action: #selector(showTabOverview(_:)))
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        displayURL.map { [$0] } ?? []
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        focusAddressIfWanted()
    }

    /// 只有空白的新标签 / 新窗口才把焦点放进地址栏；网页打开的视图、已经开始载入的标签不抢焦点。
    private var shouldFocusAddress: Bool {
        wantsAddressFocus && !isPopup && webView.url == nil && !webView.isLoading
    }

    private func focusAddressIfWanted() {
        guard shouldFocusAddress else { wantsAddressFocus = false; return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.shouldFocusAddress else { self.wantsAddressFocus = false; return }
            self.wantsAddressFocus = false
            self.addressBar.focus()
        }
    }

    func windowWillClose(_ notification: Notification) {
        session.recordClosedTab(displayURL)
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        session.controllerClosed(self)
    }

    // MARK: - WKUIDelegate

    /// 网页的 target=_blank / window.open：必须用 WebKit 给的 configuration 新建 WebView 并返回，
    /// window.opener 才在（第三方登录弹窗靠它）。带尺寸的 window.open 开成窗口，其它开成标签，和 Safari 一样。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let forcedWindow = self.webView.openNextAsWindow
        let forcedBackground = self.webView.openNextInBackgroundTab
        self.webView.openNextAsWindow = false
        self.webView.openNextInBackgroundTab = false
        if forcedWindow || windowFeatures.width != nil || windowFeatures.height != nil {
            let size = NSSize(
                width: CGFloat(windowFeatures.width?.doubleValue ?? Double(window.contentLayoutRect.width)),
                height: CGFloat(windowFeatures.height?.doubleValue ?? Double(window.contentLayoutRect.height))
            )
            return session.openWindow(url: nil, configuration: configuration, contentSize: size).webView
        }
        // ⌘点按 / 中键点按 target=_blank 链接也走这里：开在后台（加 ⇧ 切过去），和普通链接一致。
        let flags = navigationAction.modifierFlags
        let background = forcedBackground || ((flags.contains(.command) || navigationAction.buttonNumber == 2) && !flags.contains(.shift))
        return session.openTab(in: self, url: nil, configuration: configuration, background: background).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = pageAlert(frame, message)
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = pageAlert(frame, message)
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = pageAlert(frame, prompt)
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    private func pageAlert(_ frame: WKFrameInfo, _ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "\(frame.securityOrigin.host.isEmpty ? "此网页" : frame.securityOrigin.host) 显示："
        alert.informativeText = message
        return alert
    }

    /// <input type=file>
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// 摄像头 / 麦克风：和 Safari 一样每次询问。
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let what: String
        switch type {
        case .camera: what = "摄像头"
        case .microphone: what = "麦克风"
        case .cameraAndMicrophone: what = "摄像头和麦克风"
        @unknown default: what = "媒体设备"
        }
        let alert = NSAlert()
        alert.messageText = "允许「\(origin.host)」使用你的\(what)吗？"
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "不允许")
        alert.beginSheetModal(for: window) { decisionHandler($0 == .alertFirstButtonReturn ? .grant : .deny) }
    }

    /// WKWebView 默认不告诉网页窗口有多大，网页读到 outerWidth = outerHeight = 0（真 Safari 不会这样，
    /// 指纹脚本常拿它识别嵌入式 WebView）。实现这个委托回调，WebKit 才把真实窗口尺寸交给网页。
    /// 开了高级隐私保护时 WebKit 会让 outer 等于视口，和真 Safari 无痕窗口实测一致。
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewGetWindowFrame(_ webView: WKWebView, completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(window.frame)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // ⌘点按 / 中键点按链接：后台新标签（加 ⇧ 切过去）；⌥点按：下载。和 Safari 一样。
        // 只管在本页里点的链接：新窗口 / 新标签的第一次载入也带着打开它的那次点击（右键菜单、⌘点按）的信息，不能再分流一次。
        let flags = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated, navigationAction.sourceFrame.webView === webView {
            switch Self.linkClickDecision(targetIsMainFrame: navigationAction.targetFrame.map(\.isMainFrame), flags: flags, buttonNumber: navigationAction.buttonNumber) {
            case .openTab(let background):
                if let url = navigationAction.request.url {
                    decisionHandler(.cancel)
                    session.openTab(in: self, url: url, background: background)
                    return
                }
            case .download:
                decisionHandler(.download)
                return
            case .allow:
                break
            }
        }
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url {
            pendingNavigationURL = url
        }
        decisionHandler(.allow)
    }

    enum LinkClickDecision: Equatable {
        case allow
        case openTab(background: Bool)
        case download
    }

    /// 本页里点链接的分流。`targetIsMainFrame` 为 nil 表示 target=_blank / 新窗口：不在这里截，
    /// 交给 createWebViewWith 用 WebKit 给的 configuration 开新标签，window.opener 和 Referer 才保留（那里同样按 ⌘ / 中键开后台标签）。
    /// 主框架里 ⌘点按 / 中键点按开新标签（不加 ⇧ 在后台）；主框架或新窗口的 ⌥点按下载；子框架里的链接照常。
    static func linkClickDecision(targetIsMainFrame: Bool?, flags: NSEvent.ModifierFlags, buttonNumber: Int) -> LinkClickDecision {
        if targetIsMainFrame == true, flags.contains(.command) || buttonNumber == 2 {
            return .openTab(background: !flags.contains(.shift))
        }
        if targetIsMainFrame != false, flags.contains(.option) { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            navigationDiagnostics.lastMainFrameStatusCode = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || (navigationResponse.isForMainFrame && disposition.hasPrefix("attachment")) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        session.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        session.downloads.track(download)
    }

    /// HTTP 基本 / 摘要认证：弹出用户名密码，只在本次会话里记住。
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount < 3 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "登录「\(challenge.protectionSpace.host)」"
        alert.informativeText = challenge.protectionSpace.realm.map { "网站要求输入用户名和密码（\($0)）。" } ?? "网站要求输入用户名和密码。"
        let user = NSTextField(string: challenge.proposedCredential?.user ?? "")
        user.placeholderString = "用户名"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "密码"
        let stack = NSStackView(views: [user, password])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        alert.accessoryView = stack
        alert.addButton(withTitle: "登录")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = user
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationDiagnostics.lastMainFrameStatusCode = nil
        navigationDiagnostics.redirectCount = 0
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        navigationDiagnostics.redirectCount += 1
        // 重定向后 webView.url 是新的目标；如果还是旧页面的网址（新地址表示不出来），保留导航决策时记下的那个。
        if let url = webView.url, url != committedURL { pendingNavigationURL = url }
    }

    /// 真正打开了别的网页（点链接、手势后退等）：出错页记下的网址作废，⌘R 重新载入的是当前页。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let failedURL, webView.url != failedURL { self.failedURL = nil }
        committedURL = webView.url
        pendingNavigationURL = nil
        isLoadingErrorPage = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingNavigationURL = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showErrorPage(error, provisional: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showErrorPage(error, provisional: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        FileHandle.standardError.write(Data("[webcontent] 网页进程退出，重新载入\n".utf8))
        webView.reload()
    }

    /// 和 Safari 一样在页面里显示出错原因（不弹窗）。代理连不上时也走这里，不会改走直连。
    private func showErrorPage(_ error: Error, provisional: Bool) {
        let nsError = error as NSError
        let pending = pendingNavigationURL
        if provisional { pendingNavigationURL = nil }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        // 102 = 下载等策略变化打断了这次载入。
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        navigationDiagnostics.lastErrorDomain = nsError.domain
        navigationDiagnostics.lastErrorCode = nsError.code
        FileHandle.standardError.write(Data("[load-error] \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)\n".utf8))
        if isLoadingErrorPage {
            // 出错页自己没载入成功：不再生成新的出错页。
            isLoadingErrorPage = false
            FileHandle.standardError.write(Data("[load-error] 出错页本身载入失败，保留当前页面\n".utf8))
            return
        }
        guard let url = Self.errorPageURL(for: nsError, provisional: provisional, pending: pending, current: webView.url) else {
            // 不知道是哪个网址出错（错误里没有失败网址、也不是我们记下的导航）：不能拿正在显示的正常页面顶替。
            FileHandle.standardError.write(Data("[load-error] 错误里没有失败网址，保留当前页面\n".utf8))
            return
        }
        failedURL = url
        isLoadingErrorPage = true
        let host = Self.escape(url.host ?? url.absoluteString)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>无法打开页面</title><style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; font-family: -apple-system; margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center; background: Canvas; }
        main { max-width: 520px; text-align: center; color: GrayText; padding: 24px; }
        h1 { font-size: 22px; font-weight: 600; color: CanvasText; margin: 0 0 12px; }
        p { font-size: 14px; line-height: 1.5; margin: 0; }
        </style></head><body><main><h1>无法打开该页面</h1>
        <p>无法打开“\(host)”，因为：\(Self.escape(Self.errorReason(nsError)))</p></main></body></html>
        """
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
    }

    /// 出错页挂在哪个网址上：错误里带的失败网址 → 失败网址字符串 →（没提交的导航）这次导航要去的网址 →（已提交的导航）当前网址。
    /// 没提交的导航失败时 webView.url 还是之前正常显示的页面，不能拿它当失败网址，否则正常页面会被一张写着它自己网址的出错页盖掉
    /// （例如 CFNetwork 因为网址表示不出来报 -1000 bad URL 时，错误里没有失败网址）。都没有就返回 nil，保留当前页面。
    static func errorPageURL(for error: NSError, provisional: Bool, pending: URL?, current: URL?) -> URL? {
        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let text = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String, let url = URL(string: text), url.scheme != nil {
            return url
        }
        return provisional ? pending : current
    }

    /// 常见网络错误用中文说明，后面附上系统原文（便于对照日志）。
    static func errorReason(_ error: NSError) -> String {
        let reason: String?
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorBadURL), (NSURLErrorDomain, NSURLErrorUnsupportedURL), ("WebKitErrorDomain", 101):
            reason = "网址无效"
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            reason = "找不到服务器"
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            reason = "无法连接服务器"
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            reason = "连接超时"
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            reason = "没有连接到互联网"
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            reason = "网络连接中断"
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            reason = "无法建立安全连接"
        default:
            reason = nil
        }
        guard let reason else { return error.localizedDescription }
        return "\(reason)（\(error.localizedDescription)）"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - 脱敏诊断

    /// 当前窗口的环境诊断摘要（JSON）。只含环境模式、内核 / UA 版本、各项能力状态、机型目标视口与实际视口、
    /// 是否网页弹窗和脱敏的导航状态；不含环境名、环境 id、出站描述、网址的 query / fragment、Cookie、账号或令牌。
    func sanitizedDiagnosticsSummary() -> String {
        let report = session.report
        let capabilities = Dictionary(uniqueKeysWithValues: PrivacyFeature.allCases.map { feature -> (String, Any) in
            let state = report[feature]
            // 代理的说明里有服务器地址，只给状态。
            let detail = feature == .proxy ? nil : state.detail.map(Self.redact)
            return (feature.rawValue, ["state": state.name, "detail": detail as Any? ?? NSNull()])
        })
        let device: Any = session.device.map { model -> [String: Any] in
            [
                "model": model.id,
                "targetViewport": Self.sizeJSON(model.viewportSize),
                "newWindowViewport": session.viewportFit.map { Self.sizeJSON($0.actual) } as Any? ?? NSNull(),
                "scaledToFitScreen": session.viewportFit?.isScaled ?? false,
            ]
        } ?? NSNull()
        let summary: [String: Any] = [
            "environment": [
                "mode": session.profile.mode.rawValue,
                "private": session.isPrivate,
                "inspectable": session.inspectable,
                "openTabs": session.openControllers.count,
            ],
            "engine": [
                "webKit": SafarierWebKitInfo.systemWebKitVersion as Any? ?? NSNull(),
                "safari": SafarierWebKitInfo.installedSafariVersion as Any? ?? NSNull(),
                "userAgentApplicationName": webView.configuration.applicationNameForUserAgent as Any? ?? NSNull(),
                "customUserAgent": webView.customUserAgent.flatMap { $0.isEmpty ? nil : $0 } as Any? ?? NSNull(),
            ],
            "capabilities": capabilities,
            "device": device,
            "window": [
                "isPopup": isPopup,
                "tabsInWindow": tabs.count,
                "frameSize": Self.sizeJSON(window.frame.size),
                "webViewViewport": Self.sizeJSON(webView.bounds.size),
            ],
            "navigation": [
                "page": Self.sanitizeURL(displayURL) as Any? ?? NSNull(),
                "isLoading": webView.isLoading,
                "showingErrorPage": failedURL != nil,
                "lastMainFrameStatusCode": navigationDiagnostics.lastMainFrameStatusCode as Any? ?? NSNull(),
                "redirectCount": navigationDiagnostics.redirectCount,
                "lastError": navigationDiagnostics.lastErrorDomain.map { domain -> [String: Any] in
                    ["domain": domain, "code": navigationDiagnostics.lastErrorCode ?? 0]
                } as Any? ?? NSNull(),
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 只留 `scheme://host/path`：去掉用户名密码、端口、query 和 fragment，host 转小写。
    /// 没有 host 的网址（about:、data:、blob:、file: 等）只留 scheme；about: 保留页面名（about:blank）。
    static func sanitizeURL(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let host = components?.percentEncodedHost, !host.isEmpty else {
            guard scheme == "about" else { return "\(scheme):" }
            // 新版 Foundation 把 about:blank#x 的 # 编码进路径（blank%23x），所以只取开头的页面名。
            let page = (components?.percentEncodedPath ?? "").prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            return "about:\(page)"
        }
        var clean = URLComponents()
        clean.scheme = scheme
        clean.percentEncodedHost = host.lowercased()
        let path = components?.percentEncodedPath ?? ""
        clean.percentEncodedPath = path.isEmpty ? "/" : path
        return clean.string
    }

    /// 能力说明里可能带出的标识：网址只留 scheme://host/path，UUID 和 IPv4 地址换成占位符。
    private static let urlPattern = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s，。；、）)\]]+"#)

    static func redact(_ text: String) -> String {
        var result = text
        for match in urlPattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let replacement = URL(string: String(result[range])).flatMap(sanitizeURL) ?? "<url>"
            result.replaceSubrange(range, with: replacement)
        }
        result = result.replacingOccurrences(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, with: "<uuid>", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "<ip>", options: .regularExpression)
        return result
    }

    private static func sizeJSON(_ size: CGSize) -> [Int] {
        [Int(size.width.rounded()), Int(size.height.rounded())]
    }
}

/// 工具栏左侧的环境标识：彩色首字母 + 环境名；无痕环境像 Safari 一样标「私密浏览」。
@MainActor
final class ProfileBadge: NSView {
    /// 圆形色块，左右留出边距：新版工具栏把左侧几项包在一个两端是半圆的胶囊里，方块或贴边会顶出圆弧。
    static let dotDiameter: CGFloat = 18
    static let leadingInset: CGFloat = 8
    static let trailingInset: CGFloat = 6

    let dot = NSView()

    init(profile: Profile, accent: NSColor, isPrivate: Bool) {
        super.init(frame: .zero)
        let letter = NSTextField(labelWithString: profile.name.first.map { String($0).uppercased() } ?? "?")
        letter.font = .systemFont(ofSize: 10, weight: .bold)
        letter.textColor = .white
        letter.alignment = .center
        dot.wantsLayer = true
        dot.layer?.backgroundColor = accent.cgColor
        dot.layer?.cornerRadius = Self.dotDiameter / 2
        letter.translatesAutoresizingMaskIntoConstraints = false
        dot.addSubview(letter)
        let name = NSTextField(labelWithString: isPrivate ? "\(profile.name) · 私密浏览" : profile.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [dot, name])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
            letter.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
