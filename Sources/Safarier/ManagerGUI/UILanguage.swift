import AppKit
import Foundation
import SafarierCore

/// 管理器界面语言。macOS 只在进程启动时解析 Bundle 本地化，所以选了语言就带 `-AppleLanguages`
/// 重新启动自己；进程语言已经对得上时不再重启，避免启动循环。
/// 浏览器窗口的语言仍由各自环境的「区域与语言」决定，这里只影响管理器本身。
enum UILanguage {
    static let defaultsKey = "SafarierUILanguage"

    struct Language: Identifiable, Hashable {
        let id: String

        /// 语言自称，和系统设置里显示的一致。
        var title: String { UILanguage.title(for: id) }
    }

    /// 实际带 `Localizable.strings` 的语言；新增 .lproj 后菜单自动出现，不用改代码。
    static func available(in bundle: Bundle = .main) -> [Language] {
        let codes = Set(bundle.localizations)
            .filter { $0 != "Base" }
            .filter { bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: $0) != nil }
        return codes
            .sorted { title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending }
            .map(Language.init(id:))
    }

    static func title(for identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }

    static func stored(in defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: defaultsKey), !raw.isEmpty else { return nil }
        return raw
    }

    static func select(_ identifier: String?, in defaults: UserDefaults = .standard) {
        if let identifier {
            defaults.set(identifier, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
        // 菜单还在跟踪时不能立刻退出：等这次点击处理完再拉新实例。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { relaunch() }
    }

    /// 重启时要带的参数；跟随系统时不带 `-AppleLanguages`。
    static func launchArguments(for identifier: String?) -> [String] {
        guard let identifier else { return [] }
        return ["-AppleLanguages", "(\(identifier))"]
    }

    /// 启动时套用保存的选择：进程语言还不是选中的语言就重启自己。
    /// 裸可执行文件（`scripts/dev.sh`）没法重新拉起自己，保存后继续运行。
    static func applyAtLaunch() {
        guard let selected = stored() else { return }
        // 已经带着 -AppleLanguages 启动（就是我们重启的）：不再重启，避免系统把语言代码归一化后反复拉起。
        guard !ProcessInfo.processInfo.arguments.contains("-AppleLanguages") else { return }
        guard Locale.preferredLanguages.first != selected else { return }
        relaunch()
    }

    private static func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            FileHandle.standardError.write(Data("语言设置已保存，打包成 .app 后重新启动生效\n".utf8))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = launchArguments(for: stored())
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            Task { @MainActor in
                guard error == nil else {
                    let alert = NSAlert()
                    alert.messageText = L10n.text("无法重新启动 Safarier")
                    alert.informativeText = L10n.text("语言设置已保存，下次启动时生效。")
                    alert.addButton(withTitle: L10n.text("好"))
                    alert.runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}

/// App 菜单里的「语言」二级菜单。SwiftUI 的 Commands 会把嵌套菜单摊平，所以用 AppKit 插进 App 菜单；
/// 条目在菜单打开时按实际安装的 .lproj 重建，新增语言不用改代码。
@MainActor
final class LanguageMenuController: NSObject, NSMenuDelegate {
    static let shared = LanguageMenuController()
    private weak var installedItem: NSMenuItem?

    private var observing = false

    func install() {
        ensureInstalled()
        guard !observing else { return }
        observing = true
        // SwiftUI 会在状态变化时重建主菜单，把插进去的条目丢掉：每次菜单栏更新后补齐。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureInstalled() }
        }
    }

    private func ensureInstalled() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        if let installedItem, installedItem.menu === appMenu, appMenu.items.contains(where: { $0 === installedItem }) {
            return
        }
        let title = L10n.text("语言")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.delegate = self
        item.submenu = submenu
        // 放在「关于 / 检查更新」所在的分隔线之后、Services 之前。
        let index = appMenu.items.firstIndex { $0.submenu?.title == "Services" || $0.title == "Services" } ?? appMenu.items.count
        appMenu.insertItem(item, at: max(0, index - 1))
        installedItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu, languages: UILanguage.available(), selected: UILanguage.stored())
    }

    /// 菜单条目由语言表和当前选择决定；测试直接调它，不依赖运行中的 NSApp。
    static func makeSubmenu(languages: [UILanguage.Language], selected: String?) -> NSMenu {
        let menu = NSMenu(title: L10n.text("语言"))
        shared.rebuild(menu, languages: languages, selected: selected)
        return menu
    }

    private func rebuild(_ menu: NSMenu, languages: [UILanguage.Language], selected: String?) {
        menu.removeAllItems()
        let system = NSMenuItem(title: L10n.text("跟随系统"), action: #selector(choose(_:)), keyEquivalent: "")
        system.target = self
        system.representedObject = nil
        system.state = selected == nil ? .on : .off
        menu.addItem(system)
        guard !languages.isEmpty else { return }
        menu.addItem(.separator())
        for language in languages {
            let item = NSMenuItem(title: language.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.id
            item.state = selected == language.id ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        UILanguage.select(sender.representedObject as? String)
    }
}
