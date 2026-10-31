import AppKit
import WebKit
import SafarierCore
import SafarierWebKit

/// 一个 Runner 进程 = 一个环境的浏览会话。所有窗口和标签共用同一个 WKWebViewConfiguration：
/// 同一个网站数据存储、同一个代理（或 sing-box）、同样的原生引擎接口设置和机型模拟。
@MainActor
final class BrowserSession: NSObject, NSApplicationDelegate, BrowserActions {
    static let defaultContentSize = NSSize(width: 1280, height: 800)

    let profile: Profile
    let workspace: SafarierWorkspace
    let outboundDescription: String
    let configuration: WKWebViewConfiguration
    let extensionRuntime: (any WebExtensionRuntimeProtocol)?
    let device: MacDeviceModel?
    let isPrivate: Bool
    let accent: NSColor
    let startPageDetails: [String]
    let downloads = DownloadsController()
    private(set) var report: PrivacyCapabilityReport
    /// 网页打开的弹窗建 WebView 前补齐页面级隐私设置（本会话实际生效的那一套，见 `WebViewConfigurationFactory.Output.preparePopup`）。
    private let preparePopup: @MainActor (WKWebViewConfiguration) -> PrivacyCapabilityReport
    /// 4 参数导航决策回调放行前，在单次导航的 WKWebpagePreferences 上确保高级隐私保护位（同一个隐私适配器）。
    private let prepareNavigationPreferences: @MainActor (WKWebpagePreferences) -> Void
    /// 最近一个弹窗配置上的落实情况（测试和诊断用）。
    private(set) var lastPopupReport: PrivacyCapabilityReport?
    private let deviceSimulation: DeviceSimulation?
    /// 第一次给 WebView 套机型模拟的结果；和 `viewportFit` 合起来决定能力报告里的 deviceModel。
    private var deviceSimulationState: CapabilityState?
    /// 选了机型时，最近一次新窗口的目标视口和实际视口（屏幕放不下时等比缩小）。
    private(set) var viewportFit: ViewportFit?
    private var controllers: [BrowserWindowController] = []
    private var sourceWindows: [PageSourceWindowController] = []
    private(set) var agentBridge: AgentBridgeServer?
    private var reportPrinted = false
    /// 默认关闭：普通浏览时不向系统登记可远程检查的调试目标。「开发 → 允许检查网页元素」打开，
    /// ⌥⌘I / ⌥⌘C 打开检查器时也会自动打开（之后新开的窗口、网页弹窗都跟着这个值）。网页读不到它。
    private(set) var inspectable = false
    /// 最近关闭的标签的网址（最新的在最后），⇧⌘T 依次恢复。
    private(set) var closedTabURLs: [URL] = []
    static let closedTabLimit = 20
    /// 本环境的浏览历史：持久环境落盘（history/<PROFILE_ID>.json），临时环境只在内存里。
    let history: BrowsingHistoryStore
    /// 「关闭窗口前询问」等浏览器偏好（测试换成独立的 suite）。
    let preferences: UserDefaults
    static let confirmBeforeCloseKey = "SafarierConfirmBeforeClosingWindows"
    /// ⌘Q 确认后回复 AppKit（测试换掉它，不真的退出测试进程）。
    var replyToTermination: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    /// 和管理器里环境头像一样的配色（按 id 固定），方便认出窗口属于哪个环境。
    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemGreen, .systemIndigo, .systemMint, .systemBrown]

    init(
        profile: Profile,
        output: WebViewConfigurationFactory.Output,
        outboundDescription: String,
        diagnostics: SPIDiagnostics,
        workspace: SafarierWorkspace? = nil,
        history: BrowsingHistoryStore? = nil,
        preferences: UserDefaults = .standard
    ) {
        self.profile = profile
        let workspace = workspace ?? (try! SafarierWorkspace.default())
        self.workspace = workspace
        self.history = history ?? BrowsingHistoryStore.store(for: profile, in: workspace)
        self.preferences = preferences
        self.outboundDescription = outboundDescription
        self.configuration = output.configuration
        self.extensionRuntime = output.extensionRuntime
        self.report = output.report
        self.preparePopup = output.preparePopup
        self.prepareNavigationPreferences = output.prepareNavigationPreferences
        self.device = profile.deviceModel.flatMap(MacDeviceModel.preset)
        self.isPrivate = profile.mode == .ephemeral
        self.accent = Self.palette[Int(profile.id.uuid.0) % Self.palette.count]
        self.deviceSimulation = device.map { DeviceSimulation(model: $0, diagnostics: diagnostics) }
        var details = [isPrivate ? "临时环境 · 关闭窗口后不留任何网站数据" : "持久环境 · 网站数据保存在这个环境里", "出站：\(outboundDescription)"]
        if let device { details.append("机型：\(device.name)") }
        // 跟随代理时 profile 里已经是按出口 IP 解析出的语言和时区（RunnerMain 传进来的 effectiveProfile）。
        let region = [
            profile.languages.isEmpty ? nil : "语言：\(profile.languages.joined(separator: ", "))",
            profile.timeZoneIdentifier.map { "时区：\($0)" },
        ].compactMap { $0 }
        if !region.isEmpty {
            let source = profile.followProxyLanguages || profile.followProxyTimeZone ? "（跟随代理出口）" : ""
            details.append(region.joined(separator: " · ") + source)
        }
        self.startPageDetails = details
        super.init()
        downloads.onChange = { [weak self] in self?.controllers.forEach { $0.downloadsChanged() } }
    }

    // MARK: - 窗口与标签

    @discardableResult
    func startAgentBridge() throws -> AgentBridgeServer {
        if let existing = agentBridge { return existing }
        let server = AgentBridgeServer(session: self, socketURL: workspace.agentSocketURL(for: profile.id))
        try server.start()
        agentBridge = server
        return server
    }

    func stopAgentBridge() {
        agentBridge?.stop()
        agentBridge = nil
    }

    func start(url: URL?, background: Bool = false) {
        _ = try? startAgentBridge()
        let controller = openWindow(url: url, background: background)
        controller.window.center()
        if !background {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 新窗口。`configuration` 来自网页的 window.open（必须用它，opener 关系才在）；`contentSize` 是弹窗要求的尺寸。
    @discardableResult
    func openWindow(url: URL?, configuration popupConfiguration: WKWebViewConfiguration? = nil, contentSize: NSSize? = nil, background: Bool = false) -> BrowserWindowController {
        // 级联的参照窗口要在新窗口建出来之前取；当前是源代码窗口时退回最前面的浏览窗口，一个都没有就居中。
        let anchor = (keyController ?? frontmostController)?.window
        let controller = makeController(configuration: popupConfiguration, contentSize: contentSize ?? newWindowContentSize())
        if let anchor {
            controller.window.setFrameTopLeftPoint(anchor.cascadeTopLeft(from: NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY)))
        } else {
            controller.window.center()
        }
        // 系统设置「首选标签页打开文稿」为「始终」时，.automatic 会把新窗口并进当前窗口当标签：
        // 显示前临时禁止合并，显示后恢复（⌘T、拖动合并、合并所有窗口照常），⌘N 永远是独立窗口。
        controller.window.tabbingMode = .disallowed
        if background {
            controller.window.orderBack(nil)
        } else {
            controller.window.makeKeyAndOrderFront(nil)
        }
        controller.window.tabbingMode = .automatic
        show(controller, url: url, popup: popupConfiguration != nil, background: background)
        return controller
    }

    /// 在 `host` 所在窗口里加一个标签。`background` 为 true 时不切过去（⌘点按链接）。
    @discardableResult
    func openTab(in host: BrowserWindowController?, url: URL?, configuration popupConfiguration: WKWebViewConfiguration? = nil, background: Bool = false) -> BrowserWindowController {
        guard let host else { return openWindow(url: url, configuration: popupConfiguration, background: background) }
        let controller = makeController(configuration: popupConfiguration, contentSize: host.window.contentLayoutRect.size)
        host.window.addTabbedWindow(controller.window, ordered: .above)
        // 显式设选中的标签：后台打开时留在原标签，前台打开时切到新标签。
        host.window.tabGroup?.selectedWindow = background ? host.window : controller.window
        if background {
            if host.window.isKeyWindow {
                host.window.makeKeyAndOrderFront(nil)
            } else {
                host.window.orderBack(nil)
            }
        } else {
            controller.window.makeKeyAndOrderFront(nil)
        }
        show(controller, url: url, popup: popupConfiguration != nil, background: background)
        return controller
    }

    /// 网页打开的视图（window.open、target=_blank、右键「在新标签页 / 新窗口中打开」）由 WebKit 自己载入：
    /// 不显示起始页，也不把焦点交给地址栏（否则地址栏停在空白编辑状态，后台标签切过去时还会被抢焦点）。
    private func show(_ controller: BrowserWindowController, url: URL?, popup: Bool, background: Bool) {
        guard popup else { return controller.load(url) }
        controller.updateState()
        if !background { controller.window.makeFirstResponder(controller.webView) }
    }

    private func makeController(configuration popupConfiguration: WKWebViewConfiguration?, contentSize: NSSize) -> BrowserWindowController {
        let webView = makeWebView(configuration: popupConfiguration)
        let controller = BrowserWindowController(session: self, webView: webView, contentSize: contentSize, isPopup: popupConfiguration != nil)
        if let deviceSimulation {
            let state = deviceSimulation.apply(to: webView)
            if deviceSimulationState == nil {
                deviceSimulationState = state
                refreshDeviceModelState()
            }
        }
        if !reportPrinted {
            reportPrinted = true
            for line in report.lines() { print("[capability] \(line)") }
        }
        controllers.append(controller)
        if !downloads.items.isEmpty { controller.downloadsChanged() }
        return controller
    }

    private func makeWebView(configuration popupConfiguration: WKWebViewConfiguration?) -> BrowserWebView {
        // 网页打开的视图必须原样用 WebKit 交来的配置（window.opener 在里面），只在它上面补齐页面级设置。
        if let popupConfiguration { alignPopupConfiguration(popupConfiguration) }
        let webView = BrowserWebView(frame: NSRect(origin: .zero, size: Self.defaultContentSize), configuration: popupConfiguration ?? configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = inspectable
        WebViewSPI.setDeveloperExtrasEnabled(inspectable, on: webView.configuration.preferences)
        return webView
    }

    /// 4 参数导航决策回调放行前调用，见 `WebViewConfigurationFactory.Output.prepareNavigationPreferences`。
    func alignNavigationPreferences(_ preferences: WKWebpagePreferences) {
        prepareNavigationPreferences(preferences)
    }

    /// 本会话里生效的项，在弹窗上没生效就记一行日志（逐项明细不打，每个弹窗都会走一遍）。
    private func alignPopupConfiguration(_ popupConfiguration: WKWebViewConfiguration) {
        let popup = preparePopup(popupConfiguration)
        lastPopupReport = popup
        for feature in [PrivacyFeature.advancedPrivacyProtections, .webRTCDisabled, .safariAPIs, .webGPU]
        where report[feature].name == "active" && popup[feature].name != "active" {
            FileHandle.standardError.write(Data("[spi] popup：\(feature.rawValue) \(popup[feature].summary)\n".utf8))
        }
    }

    /// 新窗口内容区大小：选了机型就按机型视口（屏幕放不下等比缩小），否则沿用当前窗口或默认大小。
    private func newWindowContentSize() -> NSSize {
        if let device {
            let host = DeviceSimulation.hostVisibleFrame.size
            let screen = host.width > 0 && host.height > 0 ? host : device.viewportSize
            // 统一工具栏 52pt：和 Safari 实测一致（outerHeight − innerHeight = 52，单标签）。
            let available = CGSize(width: screen.width, height: screen.height - BrowserWindowController.chromeHeight)
            let viewport = device.viewport(fitting: available)
            let scaled = viewport == device.viewportSize ? "" : "（屏幕放不下，按比例缩小）"
            print("[device] \(device.name)：视口 \(Int(viewport.width))×\(Int(viewport.height))\(scaled)")
            recordViewportFit(ViewportFit(target: device.viewportSize, actual: viewport))
            return viewport
        }
        if let key = NSApp.keyWindow, let controller = controllers.first(where: { $0.window === key }) {
            return controller.window.contentLayoutRect.size
        }
        return Self.defaultContentSize
    }

    // MARK: - 机型视口

    struct ViewportFit: Equatable {
        var target: CGSize
        var actual: CGSize
        var isScaled: Bool { actual != target }
    }

    /// 记下新窗口实际用的视口，并立刻更新能力报告：缩小过就把 deviceModel 标成 degraded，
    /// 报告已经打印过时再补打一行，日志不会停在旧结论上。
    func recordViewportFit(_ fit: ViewportFit) {
        viewportFit = fit
        refreshDeviceModelState()
    }

    private func refreshDeviceModelState() {
        guard device != nil, let state = Self.deviceModelState(simulation: deviceSimulationState, fit: viewportFit),
              report[.deviceModel] != state else { return }
        report.set(state, for: .deviceModel)
        if reportPrinted { print("[capability] \(PrivacyFeature.deviceModel.rawValue): \(state.summary)") }
    }

    /// 机型模拟本身的结论 + 视口缩放：没缩放时原样返回；缩放过时 active 降为 degraded，并写明目标与实际视口。
    static func deviceModelState(simulation: CapabilityState?, fit: ViewportFit?) -> CapabilityState? {
        guard let fit, fit.isScaled else { return simulation }
        let scaling = "目标视口 \(Int(fit.target.width))×\(Int(fit.target.height))，屏幕放不下，实际视口缩小为 \(Int(fit.actual.width))×\(Int(fit.actual.height))"
        switch simulation {
        case .unavailable(let text)?: return .unavailable("\(text)；\(scaling)")
        case .active(let text)?, .degraded(let text)?, .unverified(let text)?: return .degraded("\(text)；\(scaling)")
        case .notRequested?, nil: return .degraded(scaling)
        }
    }

    /// 还开着的标签（测试和诊断用）。
    var openControllers: [BrowserWindowController] { controllers }

    func controllerClosed(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: - 最近关闭的标签

    /// 标签关闭时记下它的网址（起始页、about: 不记），最多留 `closedTabLimit` 个。
    func recordClosedTab(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme != "about" else { return }
        closedTabURLs.append(url)
        if closedTabURLs.count > Self.closedTabLimit { closedTabURLs.removeFirst(closedTabURLs.count - Self.closedTabLimit) }
    }

    /// ⇧⌘T：在 `host` 所在窗口（没有就是当前窗口，再没有就新建窗口）恢复最近关闭的标签。
    @discardableResult
    func reopenClosedTab(in host: BrowserWindowController?) -> BrowserWindowController? {
        guard let url = closedTabURLs.popLast() else { return nil }
        if let host = host ?? keyController ?? frontmostController {
            return openTab(in: host, url: url)
        }
        return openWindow(url: url)
    }

    // MARK: - 历史记录与上次会话

    /// 所有开着的标签要恢复的网址：按窗口、窗口里按标签顺序；起始页和非网页不算。
    var openTabURLs: [URL] {
        var seen = Set<ObjectIdentifier>()
        var urls: [URL] = []
        for controller in controllers {
            for window in controller.tabs where seen.insert(ObjectIdentifier(window)).inserted {
                if let url = controllers.first(where: { $0.window === window })?.sessionURL { urls.append(url) }
            }
        }
        return urls
    }

    /// 环境关闭时记下开着的标签，下次「重新打开上次会话的所有标签页」用。临时环境不留。
    func saveLastSession(_ urls: [URL]) {
        guard !isPrivate else { return }
        history.setLastSessionTabURLs(urls)
    }

    /// 在 `host` 所在窗口（没有就是当前窗口，再没有就新建窗口）恢复上次会话的标签。
    /// 当前标签还是空白起始页时第一个网址就开在它里面。
    @discardableResult
    func restoreLastSession(in host: BrowserWindowController?) -> [BrowserWindowController] {
        let urls = history.lastSessionTabURLs
        guard let first = urls.first else { return [] }
        var opened: [BrowserWindowController] = []
        var anchor: BrowserWindowController
        if let host = host ?? keyController ?? frontmostController {
            if host.isBlankStartPage {
                host.openURL(first)
                opened.append(host)
            } else {
                opened.append(openTab(in: host, url: first))
            }
            anchor = host
        } else {
            anchor = openWindow(url: first)
            opened.append(anchor)
        }
        for url in urls.dropFirst() {
            let tab = openTab(in: anchor, url: url, background: true)
            opened.append(tab)
            anchor = tab
        }
        return opened
    }

    /// 「清除历史记录…」的确认框。
    func makeClearHistoryAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "确定要清除环境「\(profile.name)」的所有历史记录吗？"
        alert.informativeText = "浏览记录和上次会话的标签页都会删除，网站数据和登录状态不受影响。"
        alert.addButton(withTitle: "清除历史记录")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        return alert
    }

    // MARK: - 关闭前确认

    /// 「关闭窗口前询问」，默认开启。
    var confirmsBeforeClose: Bool {
        get { preferences.object(forKey: Self.confirmBeforeCloseKey) as? Bool ?? true }
        set { preferences.set(newValue, forKey: Self.confirmBeforeCloseKey) }
    }

    /// 用户主动关窗口 / 退出时要不要先确认：开关打开时，关掉的是环境的最后一个窗口（或 ⌘Q），
    /// 或窗口里有多个标签，或正在浏览网页（不是空白起始页）就问；只关多标签窗口里的一个标签不问（和 Safari 一样）。
    static func shouldConfirmBeforeClose(enabled: Bool, tabCount: Int, browsingPage: Bool, closesEnvironment: Bool) -> Bool {
        guard enabled, tabCount > 0 else { return false }
        return closesEnvironment || tabCount > 1 || browsingPage
    }

    /// 确认框的标题和说明。
    static func closeConfirmationText(profileName: String, isPrivate: Bool, tabCount: Int, closesEnvironment: Bool) -> (message: String, informative: String) {
        var lines: [String] = []
        if tabCount > 1 { lines.append("当前共有 \(tabCount) 个打开的标签页。") }
        switch (closesEnvironment, isPrivate) {
        case (true, false): lines.append("已自动保存当前打开的标签页与登录状态，下次可在「历史记录」中一键恢复。")
        case (true, true): lines.append("这是临时无痕环境，关闭后所有网站数据将立即销毁。")
        case (false, false): lines.append("网站数据和登录状态保留在这个环境里，关掉的网页可在「历史记录」中找到。")
        case (false, true): lines.append("环境的其他窗口还开着，网站数据保留到环境关闭为止。")
        }
        return ("确认关闭环境「\(profileName)」的浏览窗口吗？", lines.joined(separator: "\n"))
    }

    /// Safari 风格的确认框：「关闭」是默认按钮（回车），「取消」接 Esc，附「不再询问（直接关闭）」。
    func makeCloseConfirmationAlert(tabCount: Int, closesEnvironment: Bool) -> NSAlert {
        let text = Self.closeConfirmationText(profileName: profile.name, isPrivate: isPrivate, tabCount: tabCount, closesEnvironment: closesEnvironment)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.informative
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再询问（直接关闭）"
        return alert
    }

    /// 确认框的结果：选了「关闭」返回 true；同时勾了「不再询问」就关掉开关。
    func acceptCloseConfirmation(_ alert: NSAlert, response: NSApplication.ModalResponse) -> Bool {
        guard response == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { confirmsBeforeClose = false }
        return true
    }

    @objc func toggleConfirmBeforeClose(_ sender: Any?) { confirmsBeforeClose.toggle() }

    @objc func showAbout(_ sender: Any?) { AboutAndUpdateController.showAbout(context: .browser) }
    @objc func checkForUpdates(_ sender: Any?) { AboutAndUpdateController.checkForUpdates(context: .browser) }
    @objc func openGitHub(_ sender: Any?) { AboutAndUpdateController.openGitHub() }

    private var keyController: BrowserWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        return controllers.first { $0.window === key }
    }

    /// 最前面的浏览窗口（当前 key window 是源代码窗口等非浏览窗口时用它）；都不在屏幕上时取最后打开的。
    var frontmostController: BrowserWindowController? {
        for window in NSApp.orderedWindows {
            if let controller = controllers.first(where: { $0.window === window }) { return controller }
        }
        return controllers.last
    }

    // MARK: - 循环显示窗口

    /// 本环境可见的窗口组，从前到后。
    func windowGroups() -> [NSWindow] {
        // 源代码窗口也算本环境的窗口，⌘` 可以在它和浏览窗口之间切换。
        let mine = Set(controllers.map { ObjectIdentifier($0.window) } + sourceWindows.map { ObjectIdentifier($0.window) })
        return WindowCycler.groups(NSApp.orderedWindows.filter { mine.contains(ObjectIdentifier($0)) && $0.isVisible })
    }

    /// ⌘` / ⌘·：本环境有两个以上窗口时在它们之间轮换，否则切到别的 Safarier 进程（其它环境或管理器）。
    func cycleWindows(forward: Bool) {
        let groups = windowGroups()
        if let target = WindowCycler.target(in: groups, forward: forward) {
            if !forward { groups.first?.orderBack(nil) }
            target.makeKeyAndOrderFront(nil)
        } else if !WindowCycler.activateOtherSafarier(forward: forward) {
            NSSound.beep()
        }
    }

    // MARK: - 页面源代码

    func showSource(_ source: String, title: String, url: URL?, relativeTo parent: NSWindow?) {
        let controller = PageSourceWindowController(source: source, title: title, url: url)
        controller.onClose = { [weak self] closed in self?.sourceWindows.removeAll { $0 === closed } }
        sourceWindows.append(controller)
        controller.show(relativeTo: parent)
    }

    // MARK: - 没有窗口时的菜单动作

    @objc func newWindow(_ sender: Any?) { openWindow(url: nil) }
    /// 当前是源代码窗口时，⌘T / ⌘L 交给最前面的浏览窗口；一个浏览窗口都没有才新建窗口。
    @objc func newTab(_ sender: Any?) {
        if let host = frontmostController {
            openTab(in: host, url: nil)
        } else {
            openWindow(url: nil)
        }
    }
    @objc func focusLocation(_ sender: Any?) {
        if let host = frontmostController {
            host.window.makeKeyAndOrderFront(nil)
            host.focusLocation(sender)
        } else {
            openWindow(url: nil)
        }
    }
    @objc func reopenClosedTab(_ sender: Any?) { reopenClosedTab(in: nil) }
    @objc func restoreLastSession(_ sender: Any?) { restoreLastSession(in: nil) }
    /// 没有浏览窗口时：⌘Y 新开一个窗口显示历史记录，最近访问在新窗口里打开。
    @objc func showHistory(_ sender: Any?) {
        (frontmostController ?? openWindow(url: nil)).displayHistory()
    }
    @objc func openHistoryEntry(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        if let host = frontmostController {
            host.openURL(url)
        } else {
            openWindow(url: url)
        }
    }
    @objc func clearHistory(_ sender: Any?) {
        if let host = frontmostController { return host.clearHistory(sender) }
        if makeClearHistoryAlert().runModal() == .alertFirstButtonReturn { history.clear() }
    }
    @objc func cycleWindowsForward(_ sender: Any?) { cycleWindows(forward: true) }
    @objc func cycleWindowsBackward(_ sender: Any?) { cycleWindows(forward: false) }

    /// 打开后右键菜单里有「检查元素」。对网页不可见。
    @objc func toggleInspectable(_ sender: Any?) {
        setInspectable(!inspectable)
    }

    /// 改所有已开标签的 isInspectable 和 developerExtras；之后新开的窗口在 makeWebView 里跟着这个值。
    func setInspectable(_ value: Bool) {
        inspectable = value
        WebViewSPI.setDeveloperExtrasEnabled(value, on: configuration.preferences)
        controllers.forEach {
            $0.webView.isInspectable = value
            WebViewSPI.setDeveloperExtrasEnabled(value, on: $0.webView.configuration.preferences)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleInspectable(_:)):
            item.state = inspectable ? .on : .off
            return true
        case #selector(reopenClosedTab(_:)):
            return !closedTabURLs.isEmpty
        case #selector(restoreLastSession(_:)):
            return !history.lastSessionTabURLs.isEmpty
        case #selector(clearHistory(_:)):
            return !history.entries.isEmpty || !history.lastSessionTabURLs.isEmpty
        case #selector(toggleConfirmBeforeClose(_:)):
            item.state = confirmsBeforeClose ? .on : .off
            return true
        case #selector(newWindow(_:)), #selector(newTab(_:)), #selector(focusLocation(_:)),
             #selector(cycleWindowsForward(_:)), #selector(cycleWindowsBackward(_:)), #selector(showHistory(_:)), #selector(openHistoryEntry(_:)):
            return true
        default:
            return false
        }
    }

    // MARK: - NSApplicationDelegate

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(url: nil) }
        return true
    }

    /// ⌘Q（菜单、Dock）：开关打开且还有浏览窗口时，在最前面的窗口上先确认。
    /// 注销、重启、关机发来的退出不问；管理器结束环境用信号，不经过这里。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let browsing = controllers.contains { $0.displayURL != nil }
        guard Self.shouldConfirmBeforeClose(enabled: confirmsBeforeClose, tabCount: controllers.count, browsingPage: browsing, closesEnvironment: true),
              !Self.isSystemInitiatedQuit, let host = keyController ?? frontmostController else { return .terminateNow }
        guard host.window.attachedSheet == nil else { return .terminateCancel }
        host.presentCloseConfirmation(tabCount: controllers.count, closesEnvironment: true) { [weak self] confirmed in
            self?.replyToTermination(confirmed)
        }
        return .terminateLater
    }

    /// 退出是不是注销 / 重启 / 关机带来的（Apple 事件里带着退出原因）。
    private static var isSystemInitiatedQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // ⌘Q 时窗口都还开着：记下全部标签。关掉最后一个窗口时已经在关窗口那里记过了。
        if !controllers.isEmpty { saveLastSession(openTabURLs) }
        stopAgentBridge()
        RunnerMain.stopSingbox()
    }
}

extension BrowserSession: NSMenuItemValidation {}
