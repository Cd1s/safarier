import AppKit
import SwiftUI
import SafarierCore

/// 图形管理器入口：不带子命令运行（双击 .app、从访达打开、终端里直接运行）时进入这里。
@MainActor
enum ManagerGUI {
    /// 单实例文件锁：进程存活期间持有，退出或重启拉起新实例前释放。
    private(set) static var managerLock: ManagerLock?

    static func start() -> Never {
        // 保存的界面语言要在建窗口前套用：没按它启动过就带 -AppleLanguages 重启自己。
        UILanguage.applyAtLaunch()
        let workspace: SafarierWorkspace
        do {
            workspace = try SafarierWorkspace.default()
            ManagerApp.workspace = workspace
        } catch {
            ManagerCLI.printError(L10n.text("无法打开元数据目录：%@", String(describing: error)))
            exit(1)
        }
        guard acquireManagerLock(for: workspace, onAlreadyRunning: { pid in
            ManagerLauncher.wakeExistingManager(pid: pid, workspace: workspace)
        }) else {
            exit(0)
        }
        _ = try? AgentSkillGuide.install()
        ManagerApp.main()
        releaseManagerLock()
        exit(0)
    }

    /// 抢占同工作目录的管理器单实例锁；已被其他管理器持有时回调 `onAlreadyRunning` 并返回 false。
    @discardableResult
    static func acquireManagerLock(
        for workspace: SafarierWorkspace,
        onAlreadyRunning: ((Int32?) -> Void)? = nil
    ) -> Bool {
        if managerLock != nil { return true }
        do {
            managerLock = try ManagerLock.acquire(in: workspace.locksDirectory)
            return true
        } catch ManagerLockError.alreadyRunning(let pid) {
            onAlreadyRunning?(pid)
            return false
        } catch {
            // 文件系统异常不阻断界面启动。
            return true
        }
    }

    /// 重启拉起新实例或退出前释放单实例锁，避免新实例误判双开。
    static func releaseManagerLock() {
        managerLock?.release()
        managerLock = nil
    }

    /// 在释放锁后执行重启启动；若启动失败则尝试重新拿回单实例锁。
    static func withLockReleasedForRelaunch(
        workspace: SafarierWorkspace?,
        launch: () throws -> Void
    ) rethrows {
        releaseManagerLock()
        do {
            try launch()
        } catch {
            if let workspace { _ = acquireManagerLock(for: workspace) }
            throw error
        }
    }

    static func showAgentSetup() {
        let alert = NSAlert()
        alert.messageText = L10n.text("AI Agent 接入")
        do {
            _ = try AgentSkillGuide.install()
            alert.informativeText = L10n.text("已同步 safarier-browser Skill 到 Claude Code 与 Codex 的技能目录。重新加载 Agent 的技能列表后，即可操作环境、填表和截图。其他客户端可导入指南。\n\n遇到验证码或需要确认的步骤，可用 agent focus 切回窗口人工完成。")
        } catch {
            alert.informativeText = L10n.text("Skill 同步失败：%@\n可拷贝指南后手动导入。", error.localizedDescription)
        }
        alert.addButton(withTitle: L10n.text("拷贝接入指南"))
        alert.addButton(withTitle: L10n.text("关闭"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AgentSkillGuide.markdown, forType: .string)
        }
    }
}

struct ManagerApp: App {
    static let mainWindowID = "manager"

    /// `ManagerGUI.start()` 在调用 `main()` 之前设置。
    static var workspace: SafarierWorkspace!

    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var appDelegate
    @StateObject private var model = ManagerModel(workspace: ManagerApp.workspace)
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Safarier", id: Self.mainWindowID) {
            SafarierAppView(model: model)
                .frame(minWidth: 860, minHeight: 540)
                .background(ManagerWindowTracker { window in
                    appDelegate.trackMainWindow(window)
                })
                .onAppear {
                    appDelegate.registerOpenWindow { openWindow(id: Self.mainWindowID) }
                }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button("关于 Safarier") { AboutAndUpdateController.showAbout() }
                Button("检查更新…") { AboutAndUpdateController.checkForUpdates() }
            }
            CommandGroup(replacing: .help) {
                Button("Safarier GitHub 主页") { AboutAndUpdateController.openGitHub() }
                Button("查看最新版本 (GitHub Releases)") { AboutAndUpdateController.openReleases() }
                Button("反馈问题 (GitHub Issues)") { AboutAndUpdateController.openIssues() }
            }
            CommandGroup(replacing: .newItem) {
                Button("新建环境…") { model.sheet = .newProfile }
                    .keyboardShortcut("n")
                Button("添加订阅…") { model.sheet = .newSubscription }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("添加代理…") { model.sheet = .newProxy }
            }
            CommandMenu("环境") {
                Button("启动浏览器") { model.selectedProfile.map(model.launch) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedProfile.map { model.runState($0.id) != .stopped } ?? true)
                Button("复制环境") { model.selectedProfile.map { _ = model.duplicate($0) } }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selectedProfile == nil)
                Divider()
                Button("刷新全部订阅") { model.refreshAllSubscriptions() }
                    .disabled(model.subscriptions.isEmpty)
                Button("重新读取数据") { model.reload() }
                    .keyboardShortcut("r")
            }
            CommandMenu("AI Agent") {
                Button("AI Agent 接入…") { ManagerGUI.showAgentSetup() }
            }
            CommandGroup(after: .windowArrangement) {
                Button("打开环境管理器") {
                    appDelegate.registerOpenWindow { openWindow(id: Self.mainWindowID) }
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                // 每个环境的浏览器是独立进程：⌘` 在管理器和正在运行的浏览器窗口之间轮换（中文输入法下的 ⌘· 由 ManagerAppDelegate 接住）。
                Button("循环显示浏览器窗口") {
                    if !WindowCycler.activateOtherSafarier(forward: true) { NSSound.beep() }
                }
                .keyboardShortcut("`", modifiers: .command)
            }
        }
    }
}

/// 只读捕获 SwiftUI 主窗口引用，不覆盖 SwiftUI 内部维护的 `NSWindow.delegate`。
private struct ManagerWindowTracker: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onWindow = onWindow
        if let window = nsView.window { onWindow(window) }
    }

    final class TrackerView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

@MainActor
final class ManagerAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var wakeupObserver: NSObjectProtocol?
    private var openMainWindowHandler: (@MainActor () -> Void)?
    private weak var trackedMainWindow: NSWindow?
    private var hasFinishedLaunching = false

    func registerOpenWindow(_ action: @escaping @MainActor () -> Void) {
        openMainWindowHandler = action
    }

    func trackMainWindow(_ window: NSWindow) {
        trackedMainWindow = window
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 终端里直接运行裸二进制（没有 Info.plist）时，默认不进 Dock，窗口也不会到前台。
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hasFinishedLaunching = true
        // SwiftUI 的 Commands 会把嵌套语言菜单摊平，二级菜单用 AppKit 插进 App 菜单；
        // 放到下一个 runloop，等 SwiftUI 把主菜单建好。
        DispatchQueue.main.async { LanguageMenuController.shared.install() }
        NSApp.activate(ignoringOtherApps: true)
        if let workspace = ManagerApp.workspace {
            startObservingWakeup(scope: workspace.managerWakeupScope)
        }
        // SwiftUI 菜单不能放隐藏的备用快捷键：⌘·（中文输入法下的 ⌘`）和 ⇧⌘` 等反向组合在这里接住。⌘` 本身交给菜单。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let forward = WindowCycler.direction(for: event),
                  !(forward && event.charactersIgnoringModifiers == "`") else { return event }
            MainActor.assumeIsolated {
                if !WindowCycler.activateOtherSafarier(forward: forward) { NSSound.beep() }
            }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopObservingWakeup()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        ManagerGUI.releaseManagerLock()
    }

    /// 遵循 macOS 原生惯例：关掉主窗口后管理器留在后台，随时可再次唤醒；⌘Q 才退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || !hasVisibleMainWindow {
            showMainWindow()
        }
        return true
    }

    /// 从浏览器按 ⌘` 切回隐藏中的管理器进程时，自动把主窗口重新拉出来。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasFinishedLaunching, !hasVisibleMainWindow else { return }
        showMainWindow()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: L10n.text("打开环境管理器"), action: #selector(openManagerFromDock(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func openManagerFromDock(_ sender: Any?) {
        showMainWindow()
    }

    /// 监听同工作目录的本机唤醒通知，供浏览器进程或重复启动的管理器唤出主窗。
    func startObservingWakeup(scope: String) {
        stopObservingWakeup()
        wakeupObserver = DistributedNotificationCenter.default().addObserver(
            forName: ManagerWakeup.notificationName,
            object: scope,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showMainWindow()
            }
        }
    }

    func stopObservingWakeup() {
        if let wakeupObserver {
            DistributedNotificationCenter.default().removeObserver(wakeupObserver)
            self.wakeupObserver = nil
        }
    }

    var hasVisibleMainWindow: Bool {
        if let window = trackedMainWindow, window.isVisible, !window.isMiniaturized {
            return true
        }
        return NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain && !($0 is NSPanel) && !$0.isSheet }
    }

    /// 统一唤出主管理窗口：已有窗口直接前置/取消最小化，已关闭时经 SwiftUI `openWindow` 重新打开。
    func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = trackedMainWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let openMainWindowHandler {
            openMainWindowHandler()
            DispatchQueue.main.async { [weak self] in
                self?.trackedMainWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else if let window = trackedMainWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
