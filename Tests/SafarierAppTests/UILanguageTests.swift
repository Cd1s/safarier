import AppKit
import XCTest
import SafarierCore
@testable import Safarier

/// 管理器界面语言：保存值、重启参数、菜单里的语言清单，以及 AppKit「语言」子菜单的条目/勾选；
/// 重启参数必须仍被当成图形管理器（而不是未知子命令）——第一版用自定义标记参数，重启后的进程直接退出了。
///
/// 菜单由 AppKit 构建（SwiftUI Commands 会摊平嵌套菜单），这里只检查菜单结构，不触发条目动作。
@MainActor
final class UILanguageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var bundleRoot: URL!

    override func setUpWithError() throws {
        suiteName = "SafarierUILanguageTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-language-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let bundleRoot {
            try? FileManager.default.removeItem(at: bundleRoot)
        }
        bundleRoot = nil
    }

    /// 没存过语言返回 nil（跟随系统）；空值也按没存处理；其余原样返回，不做白名单校验。
    func testStoredReportsMissingEmptyAndRawValues() {
        XCTAssertNil(UILanguage.stored(in: defaults), "没存过语言")

        defaults.set("", forKey: UILanguage.defaultsKey)
        XCTAssertNil(UILanguage.stored(in: defaults), "空字符串按没存处理")

        for raw in ["en", "zh-Hans", "fr"] {
            defaults.set(raw, forKey: UILanguage.defaultsKey)
            XCTAssertEqual(UILanguage.stored(in: defaults), raw)
        }
    }

    /// 重启参数：跟随系统不带参数；显式语言带成对的 `-AppleLanguages` 和带括号的语言标签。
    func testLaunchArgumentsUseAppleLanguagesOnlyForExplicitChoice() {
        XCTAssertEqual(UILanguage.launchArguments(for: nil), [])
        XCTAssertEqual(UILanguage.launchArguments(for: "en"), ["-AppleLanguages", "(en)"])
        XCTAssertEqual(UILanguage.launchArguments(for: "zh-Hans"), ["-AppleLanguages", "(zh-Hans)"])
    }

    /// 菜单只列出真正带 `Localizable.strings` 的语言：空的 .lproj 不能出现在菜单里。
    func testAvailableListsOnlyLanguagesWithLocalizedTable() throws {
        let bundle = try makeBundle(localized: ["en", "zh-Hans"], empty: "fr")

        let languages = UILanguage.available(in: bundle)

        XCTAssertEqual(Set(languages.map(\.id)), Set(["en", "zh-Hans"]))
        XCTAssertEqual(languages.count, 2, "没有 Localizable.strings 的 .lproj 必须被排除")
        for language in languages {
            XCTAssertFalse(language.id.isEmpty)
            XCTAssertFalse(language.title.isEmpty, "\(language.id) 的菜单标题为空")
        }
        XCTAssertEqual(languages.first { $0.id == "en" }?.title, "English")
    }

    /// 一个带本地化表的都没有时，菜单为空而不是崩掉。
    func testAvailableIsEmptyWithoutLocalizedTables() throws {
        let bundle = try makeBundle(localized: [], empty: "en")

        XCTAssertEqual(UILanguage.available(in: bundle).map(\.id), [])
    }

    /// 标题是语言自称；未知代码退回显示原始代码，而不是空字符串。
    func testTitleUsesEndonymAndFallsBackToIdentifier() {
        XCTAssertEqual(UILanguage.title(for: "en"), "English")
        XCTAssertFalse(UILanguage.title(for: "zh-Hans").isEmpty)
        XCTAssertNotEqual(UILanguage.title(for: "zh-Hans"), "zh-Hans", "已知语言要用自称")
        XCTAssertEqual(UILanguage.title(for: "zz"), "zz")
    }

    /// 没有可选语言时只有一个「跟随系统」条目：不能多出分隔线，条目要能触发动作。
    func testSubmenuShowsOnlyFollowSystemWhenNoLanguages() throws {
        let menu = LanguageMenuController.makeSubmenu(languages: [], selected: nil)

        XCTAssertEqual(menu.items.count, 1, "空语言表不应出现分隔线或额外条目")
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertFalse(item.isSeparatorItem)
        XCTAssertEqual(item.title, L10n.text("跟随系统"))
        XCTAssertEqual(item.state, .on, "没存语言时跟随系统应勾上")
        XCTAssertNil(item.representedObject, "跟随系统用 nil 表示")
        XCTAssertNotNil(item.target)
        XCTAssertNotNil(item.action)

        let notFollowing = LanguageMenuController.makeSubmenu(languages: [], selected: "en")
        XCTAssertEqual(notFollowing.items.count, 1)
        XCTAssertEqual(notFollowing.items.first?.state, .off, "存了语言时跟随系统不勾")
    }

    /// 语言条目按传入顺序排列（不再排序），勾选只落在当前选择上，语言值放进 representedObject。
    func testSubmenuListsLanguagesInGivenOrderAndChecksSelection() throws {
        let languages = [UILanguage.Language(id: "zh-Hans"), UILanguage.Language(id: "en")]

        for selected in [nil, "en", "zh-Hans"] as [String?] {
            let menu = LanguageMenuController.makeSubmenu(languages: languages, selected: selected)

            XCTAssertEqual(menu.items.count, 4, "1 个跟随系统 + 1 条分隔线 + 2 个语言")
            let system = menu.items[0]
            XCTAssertEqual(system.title, L10n.text("跟随系统"))
            XCTAssertEqual(system.state, selected == nil ? .on : .off, "选中 \(selected ?? "nil")")
            XCTAssertTrue(menu.items[1].isSeparatorItem, "分隔线必须紧跟跟随系统")

            for (offset, language) in languages.enumerated() {
                let item = menu.items[offset + 2]
                XCTAssertEqual(item.title, language.title)
                XCTAssertEqual(item.representedObject as? String, language.id)
                XCTAssertEqual(
                    item.state,
                    selected == language.id ? .on : .off,
                    "选中 \(selected ?? "nil") 时检查 \(language.id) 的勾选"
                )
                XCTAssertFalse(item.isSeparatorItem)
                XCTAssertNotNil(item.target, "\(language.id) 必须能被点")
                XCTAssertNotNil(item.action, "\(language.id) 必须有选择动作")
            }
        }
    }

    /// 重启时带的参数要能穿过 `ExecutableRole.resolve` 回到图形管理器；
    /// 否则进程按命令行 Manager 解析参数并退出，界面根本不会出现。
    func testRelaunchArgumentsResolveToManager() {
        for identifier in [nil, "en", "zh-Hans"] as [String?] {
            let arguments = UILanguage.launchArguments(for: identifier)
            XCTAssertEqual(ExecutableRole.resolve(arguments), .manager, "\(arguments)")
        }
        XCTAssertEqual(ExecutableRole.resolve(["-AppleLanguages", "(en)", "-NSFoo", "bar"]), .manager)
    }

    /// 语言参数不能盖掉真正的子命令路由。
    func testSubcommandRoutingIsUnchanged() {
        XCTAssertEqual(ExecutableRole.resolve(["profile", "list"]), .cli)
        XCTAssertEqual(ExecutableRole.resolve(["run", "--profile", "X"]), .runner)
    }

    // MARK: - Helpers

    /// 造一个最小 .app 结构：只把 `localized` 的语言放 `Localizable.strings`；
    /// `empty` 里的语言只有 .lproj 目录，用来证明菜单不按目录猜语言。
    private func makeBundle(localized: [String], empty: String) throws -> Bundle {
        let resources = bundleRoot.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "tests.safarier.ui-language",
            "CFBundleExecutable": "Safarier",
            "CFBundlePackageType": "APPL",
            "CFBundleDevelopmentRegion": "en",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundleRoot.appendingPathComponent("Contents/Info.plist"))

        for code in localized {
            let lproj = resources.appendingPathComponent("\(code).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try "\"greeting\" = \"hello\";\n".write(
                to: lproj.appendingPathComponent("Localizable.strings"),
                atomically: true,
                encoding: .utf8
            )
        }

        let emptyLproj = resources.appendingPathComponent("\(empty).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyLproj, withIntermediateDirectories: true)

        return try XCTUnwrap(Bundle(path: bundleRoot.path))
    }
}
