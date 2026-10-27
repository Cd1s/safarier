import AppKit
import SwiftUI
import SafarierCore

/// 图形管理器入口：不带子命令运行（双击 .app、从访达打开、终端里直接运行）时进入这里。
@MainActor
enum ManagerGUI {
    static func start() -> Never {
        do {
            ManagerApp.workspace = try SafarierWorkspace.default()
        } catch {
            ManagerCLI.printError("无法打开元数据目录：\(error)")
            exit(1)
        }
        ManagerApp.main()
        exit(0)
    }
}

struct ManagerApp: App {
    /// `ManagerGUI.start()` 在调用 `main()` 之前设置。
    static var workspace: SafarierWorkspace!

    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var appDelegate
    @StateObject private var model = ManagerModel(workspace: ManagerApp.workspace)

    var body: some Scene {
        Window("Safarier", id: "manager") {
            SafarierAppView(model: model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("新建环境…") { model.sheet = .newProfile }
                    .keyboardShortcut("n")
                Button("添加订阅…") { model.sheet = .newSubscription }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("环境") {
                Button("启动浏览器") { model.selectedProfile.map(model.launch) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedProfile.map { model.runState($0.id) != .stopped } ?? true)
                Button("编辑…") { model.selectedProfile.map { model.sheet = .editProfile($0) } }
                    .keyboardShortcut("e")
                    .disabled(model.selectedProfile == nil)
                Button("复制环境") { model.selectedProfile.map { _ = model.duplicate($0) } }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selectedProfile == nil)
                Divider()
                Button("刷新全部订阅") { model.refreshAllSubscriptions() }
                    .disabled(model.subscriptions.isEmpty)
                Button("重新读取数据") { model.reload() }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .windowArrangement) {
                // 每个环境的浏览器是独立进程：⌘` 在管理器和正在运行的浏览器窗口之间轮换（中文输入法下的 ⌘· 由 ManagerAppDelegate 接住）。
                Button("循环显示浏览器窗口") {
                    if !WindowCycler.activateOtherSafarier(forward: true) { NSSound.beep() }
                }
                .keyboardShortcut("`", modifiers: .command)
            }
        }
    }
}

@MainActor
final class ManagerAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 终端里直接运行裸二进制（没有 Info.plist）时，默认不进 Dock，窗口也不会到前台。
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
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

    /// 只有一个管理窗口，关掉就退出；已经启动的 Runner 是独立进程，不受影响。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
