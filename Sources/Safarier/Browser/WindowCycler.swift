import AppKit

/// ⌘` / ⌘·（中文输入法下）循环显示窗口：同一环境开了几个窗口就在它们之间轮换（同一组标签算一个窗口）；
/// 只有一个窗口时切到别的 Safarier 进程（其它环境的浏览窗口或管理器）。每个环境是独立进程，系统的窗口循环只在本进程里转，
/// 所以跨环境要自己找。
@MainActor
enum WindowCycler {
    /// 按前后顺序的窗口组：同一组标签只取当前选中的那个标签窗口，去重保持顺序。
    static func groups(_ ordered: [NSWindow]) -> [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        var out: [NSWindow] = []
        for window in ordered {
            let representative = window.tabGroup?.selectedWindow ?? window
            if seen.insert(ObjectIdentifier(representative)).inserted { out.append(representative) }
        }
        return out
    }

    /// 向前：把最后面的窗口拿到最前（连按依次走遍所有窗口）；向后：最前的放到最后，第二个拿到最前。不足两个返回 nil。
    static func target<Window: AnyObject>(in groups: [Window], forward: Bool) -> Window? {
        guard groups.count >= 2 else { return nil }
        return forward ? groups.last : groups[1]
    }

    /// 在所有 Safarier 进程（含自己）里按进程号排好，取自己的下一个（向后取上一个），首尾相接。
    static func nextProcess(_ pids: [pid_t], current: pid_t, forward: Bool) -> pid_t? {
        let all = Set(pids).union([current]).sorted()
        guard all.count >= 2, let index = all.firstIndex(of: current) else { return nil }
        return all[(index + (forward ? 1 : all.count - 1)) % all.count]
    }

    /// 本机其它正在运行、有界面的 Safarier 进程：同一个 bundle（.app）或同一个可执行文件（直接运行的二进制）。
    static func otherSafarierApplications() -> [NSRunningApplication] {
        let current = NSRunningApplication.current
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != current.processIdentifier, !app.isTerminated, app.activationPolicy == .regular else { return false }
            if let bundleID = current.bundleIdentifier, app.bundleIdentifier == bundleID { return true }
            return executable != nil && app.executableURL?.resolvingSymlinksInPath() == executable
        }
    }

    /// 切到下一个 Safarier 进程；没有别的进程时返回 false。
    @discardableResult
    static func activateOtherSafarier(forward: Bool) -> Bool {
        let others = otherSafarierApplications()
        let current = NSRunningApplication.current.processIdentifier
        guard let pid = nextProcess(others.map(\.processIdentifier), current: current, forward: forward),
              let app = others.first(where: { $0.processIdentifier == pid }) else { return false }
        return app.activate(options: [.activateAllWindows])
    }

    /// 键盘事件是不是循环显示窗口：⌘` / ⌘·（向前）、⇧⌘` / ⇧⌘~ / ⇧⌘· / ⇧⌘～（向后）。不是返回 nil。
    static func direction(for event: NSEvent) -> Bool? {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, ["`", "·"].contains(characters) { return true }
        if flags == [.command, .shift], ["`", "~", "·", "～"].contains(characters) { return false }
        return nil
    }
}
