import AppKit
import XCTest
import SafarierCore
@testable import Safarier

@MainActor
final class StartupTabShortcutTests: XCTestCase {
    private var environment: TestBrowserEnvironment!

    override func setUp() async throws {
        environment = try TestBrowserEnvironment()
    }

    override func tearDown() async throws {
        environment.tearDown()
        environment = nil
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: - 任务 2.1：BrowserSession 原子写入、撤销与边界处理

    func testSessionAddAppendHomeReenableAndUndo() throws {
        let initialFirst = StartupTab(url: url("https://mail.example.com/"), isEnabled: true)
        let pausedSecond = StartupTab(url: url("https://calendar.example.com/"), isEnabled: false)
        let profile = Profile(name: "工作号", mode: .persistent, notes: "初始备注", startupTabs: [initialFirst, pausedSecond])
        try environment.workspace.profiles.insert(profile)

        let session = try environment.makeSession(profile: profile)
        var notifiedScopes: [String] = []
        session.onProfilesDidChange = { notifiedScopes.append($0) }

        // 模拟管理器在外部修改了备注与代理 ID，浏览器后续写入不能覆盖它们。
        let externalProxyID = UUID()
        try environment.workspace.profiles.mutate(id: profile.id) { persisted in
            persisted.proxyID = externalProxyID
            persisted.notes = "管理器新备注"
        }

        // 1. 末尾追加
        let appended = try session.addOrReenableStartupTab(url: url("https://work.example.com/inbox"), position: .append)
        XCTAssertFalse(appended.wasReenabled)
        XCTAssertFalse(appended.setAsHome)
        XCTAssertEqual(appended.totalCount, 3)
        XCTAssertEqual(notifiedScopes, [ProfilesSyncNotification.workspaceScope(for: environment.workspace.root)])

        var persisted = try XCTUnwrap(environment.workspace.profiles.record(id: profile.id))
        XCTAssertEqual(persisted.proxyID, externalProxyID)
        XCTAssertEqual(persisted.notes, "管理器新备注")
        XCTAssertEqual(persisted.startupTabs.map(\.url.absoluteString), [
            "https://mail.example.com/",
            "https://calendar.example.com/",
            "https://work.example.com/inbox",
        ])

        // 2. 撤销末尾追加
        _ = try session.undoStartupTabChange(appended.undoToken)
        persisted = try XCTUnwrap(environment.workspace.profiles.record(id: profile.id))
        XCTAssertEqual(persisted.startupTabs.map(\.id), [initialFirst.id, pausedSecond.id])

        // 3. 重新启用已暂停项并设为首页（移到第 1 位，同步 session.profile.startURL）
        let reenabled = try session.addOrReenableStartupTab(
            url: url("https://calendar.example.com"),
            position: .home,
            reenableTabID: pausedSecond.id
        )
        XCTAssertTrue(reenabled.wasReenabled)
        XCTAssertTrue(reenabled.setAsHome)
        XCTAssertEqual(reenabled.totalCount, 2, "重新启用不产生重复项")
        XCTAssertEqual(session.profile.startURL, url("https://calendar.example.com/"))

        persisted = try XCTUnwrap(environment.workspace.profiles.record(id: profile.id))
        XCTAssertEqual(persisted.startupTabs.map(\.id), [pausedSecond.id, initialFirst.id])
        XCTAssertTrue(persisted.startupTabs[0].isEnabled)

        // 4. 撤销重新启用：恢复暂停态与原索引 1，同时会话首页还原为 initialFirst
        _ = try session.undoStartupTabChange(reenabled.undoToken)
        persisted = try XCTUnwrap(environment.workspace.profiles.record(id: profile.id))
        XCTAssertEqual(persisted.startupTabs.map(\.id), [initialFirst.id, pausedSecond.id])
        XCTAssertFalse(persisted.startupTabs[1].isEnabled)
        XCTAssertEqual(session.profile.startURL, initialFirst.url)

        // 5. 设为首页新增项
        let asHome = try session.addOrReenableStartupTab(url: url("https://portal.example.com"), position: .home)
        XCTAssertTrue(asHome.setAsHome)
        XCTAssertEqual(session.profile.startURL, url("https://portal.example.com"))
        persisted = try XCTUnwrap(environment.workspace.profiles.record(id: profile.id))
        XCTAssertEqual(persisted.startupTabs.first?.url, url("https://portal.example.com"))
    }

    func testSessionAddFailsSafelyWhenProfileWasDeletedExternally() throws {
        let profile = Profile(name: "已删环境", mode: .persistent)
        let session = try environment.makeSession(profile: profile)
        var notified = false
        session.onProfilesDidChange = { _ in notified = true }

        XCTAssertThrowsError(try session.addOrReenableStartupTab(url: url("https://example.com"), position: .append)) { error in
            XCTAssertEqual(error as? StartupTabShortcutError, .profileNotFound)
        }
        XCTAssertThrowsError(try session.undoStartupTabChange(.added(tabID: UUID()))) { error in
            XCTAssertEqual(error as? StartupTabShortcutError, .profileNotFound)
        }
        XCTAssertFalse(notified)
        XCTAssertTrue(try environment.workspace.profiles.all().isEmpty)
    }

    func testDuplicateMatchPrefersEnabledOverPausedSameURL() {
        let pausedFirst = StartupTab(url: url("https://example.com/"), isEnabled: false)
        let enabledSecond = StartupTab(url: url("https://example.com"), isEnabled: true)
        let sheet = AddStartupTabSheetController(
            profileName: "工作号",
            initialURL: url("https://example.com"),
            existingTabs: [pausedFirst, enabledSecond]
        )
        XCTAssertEqual(sheet.duplicateMatch, .enabled(index: 1))
        XCTAssertEqual(sheet.confirmButton.title, L10n.text("仍要添加"))
    }

    // MARK: - 任务 2.2：AddStartupTabSheetController 原生表单交互

    func testSheetValidationTrimmingDuplicateAndKeyboardActions() throws {
        let existingEnabled = StartupTab(url: url("https://mail.example.com/"), isEnabled: true)
        let existingPaused = StartupTab(url: url("https://calendar.example.com/"), isEnabled: false)
        let originalURL = url("https://docs.example.com/project/issues?q=open#top")

        let sheet = AddStartupTabSheetController(
            profileName: "工作号",
            initialURL: originalURL,
            existingTabs: [existingEnabled, existingPaused]
        )

        XCTAssertEqual(sheet.cancelButton.keyEquivalent, "\u{1b}")
        XCTAssertEqual(sheet.confirmButton.keyEquivalent, "\r")
        XCTAssertEqual(sheet.urlField.stringValue, originalURL.absoluteString)
        XCTAssertTrue(sheet.confirmButton.isEnabled)
        XCTAssertTrue(sheet.trimQueryButton.isEnabled)
        XCTAssertTrue(sheet.trimOriginButton.isEnabled)
        XCTAssertTrue(sheet.restoreButton.isHidden)

        // 去掉参数 → 仅保留域名 → 还原原网址
        sheet.trimQueryClicked(nil)
        XCTAssertEqual(sheet.urlField.stringValue, "https://docs.example.com/project/issues")
        XCTAssertFalse(sheet.trimQueryButton.isEnabled)
        XCTAssertTrue(sheet.trimOriginButton.isEnabled)
        XCTAssertFalse(sheet.restoreButton.isHidden)

        sheet.trimOriginClicked(nil)
        XCTAssertEqual(sheet.urlField.stringValue, "https://docs.example.com")
        XCTAssertFalse(sheet.trimOriginButton.isEnabled)

        sheet.restoreClicked(nil)
        XCTAssertEqual(sheet.urlField.stringValue, originalURL.absoluteString)
        XCTAssertTrue(sheet.restoreButton.isHidden)

        // 无效与空输入阻止提交
        for invalid in ["", "   ", "file:///tmp/a", "javascript:alert(1)", "bad url"] {
            sheet.urlField.stringValue = invalid
            sheet.refreshValidationState()
            XCTAssertFalse(sheet.confirmButton.isEnabled, "非法输入应禁用提交：\(invalid)")
            if !invalid.trimmingCharacters(in: .whitespaces).isEmpty {
                XCTAssertFalse(sheet.feedbackLabel.isHidden)
            }
        }

        // 省略协议自动补全
        sheet.urlField.stringValue = "example.com/dashboard"
        sheet.refreshValidationState()
        XCTAssertTrue(sheet.confirmButton.isEnabled)
        XCTAssertFalse(sheet.feedbackLabel.isHidden)
        XCTAssertTrue(sheet.feedbackLabel.stringValue.contains("https://example.com/dashboard"))

        // 命中已启用重复项 → 按钮变为「仍要添加」
        sheet.urlField.stringValue = "https://MAIL.EXAMPLE.COM"
        sheet.refreshValidationState()
        XCTAssertEqual(sheet.duplicateMatch, .enabled(index: 0))
        XCTAssertEqual(sheet.confirmButton.title, L10n.text("仍要添加"))

        // 命中已暂停重复项 → 按钮变为「重新启用」且提交携带 reenableTabID
        sheet.urlField.stringValue = "https://calendar.example.com"
        sheet.refreshValidationState()
        XCTAssertEqual(sheet.duplicateMatch, .paused(tabID: existingPaused.id, index: 1))
        XCTAssertEqual(sheet.confirmButton.title, L10n.text("重新启用"))

        // 提交失败时不关闭 Sheet，显示错误提示
        var submittedReenableID: UUID?
        var finishedCalled = false
        sheet.onFinished = { _ in finishedCalled = true }
        sheet.onSubmit = { _, _, reenableID in
            submittedReenableID = reenableID
            return .failure(StartupTabShortcutError.profileNotFound)
        }
        sheet.confirmClicked(nil)
        XCTAssertEqual(submittedReenableID, existingPaused.id)
        XCTAssertFalse(finishedCalled, "提交失败时不应关闭弹窗")
        XCTAssertFalse(sheet.feedbackLabel.isHidden)
        XCTAssertEqual(sheet.feedbackLabel.stringValue, StartupTabShortcutError.profileNotFound.localizedDescription)

        // 取消关闭
        var finishedResult: StartupTabSaveResult? = StartupTabSaveResult(
            undoToken: .added(tabID: UUID()),
            totalCount: 1,
            wasReenabled: false,
            setAsHome: false,
            updatedTabs: []
        )
        sheet.onFinished = { finishedResult = $0 }
        sheet.cancelClicked(nil)
        XCTAssertNil(finishedResult)
    }

    // MARK: - 任务 2.3：菜单挂载、窗口 Sheet 防重复、底部 Toast 撤销与 ⇧⌘H 联动

    func testMenuValidationWindowSheetToastAndGoHomeSync() throws {
        _ = NSApplication.shared
        let fileMenu = try XCTUnwrap(BrowserMenu.make().items.first { $0.title == L10n.text("文件") }?.submenu)
        let menuItem = try XCTUnwrap(fileMenu.items.first { $0.action == #selector(BrowserActions.addStartupTab(_:)) })
        XCTAssertEqual(menuItem.keyEquivalent, "d")
        XCTAssertEqual(menuItem.keyEquivalentModifierMask, .command)

        let profile = Profile(name: "主环境", mode: .persistent)
        try environment.workspace.profiles.insert(profile)
        let session = try environment.makeSession(profile: profile)
        session.onProfilesDidChange = { _ in }

        // 无窗口时由 BrowserSession 兜底校验，菜单项必须禁用。
        XCTAssertFalse(session.validateMenuItem(menuItem))

        let controller = session.openWindow(url: nil)
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertNil(controller.initialStartupTabURL, "空白起始页默认不预填网址")

        // 触发 ⌘D 打开 Sheet
        controller.addStartupTab(nil)
        let sheet = try XCTUnwrap(controller.addStartupTabSheet)
        XCTAssertEqual(sheet.urlField.stringValue, "")
        XCTAssertFalse(controller.validateMenuItem(menuItem), "Sheet 已打开时禁止重复触发")

        // 防重复弹出
        controller.addStartupTab(nil)
        XCTAssertTrue(controller.addStartupTabSheet === sheet)

        // 手动输入网址并设为首页，确认提交
        sheet.urlField.stringValue = "docs.example.com/start"
        sheet.refreshValidationState()
        sheet.positionPopUp.selectItem(at: StartupTabInsertionPosition.home.rawValue)
        sheet.confirmClicked(nil)

        XCTAssertNil(controller.addStartupTabSheet)
        XCTAssertEqual(session.profile.startURL, url("https://docs.example.com/start"))

        // 底部轻提示出现且带撤销按钮
        let toast = try XCTUnwrap(controller.startupTabToast)
        XCTAssertFalse(toast.isHidden)
        XCTAssertFalse(toast.undoButton.isHidden)

        // 点击撤销：磁盘与会话首页均回滚为空
        toast.undoClicked(nil)
        let persisted = try XCTUnwrap(environment.workspace.profiles.record(id: profile.id))
        XCTAssertTrue(persisted.startupTabs.isEmpty)
        XCTAssertNil(session.profile.startURL)
        XCTAssertTrue(toast.undoButton.isHidden)

        // 外部直接 endSheet 时应自动清理 addStartupTabSheet，允许后续再次按 ⌘D 打开
        controller.addStartupTab(nil)
        let secondSheet = try XCTUnwrap(controller.addStartupTabSheet)
        controller.window.endSheet(secondSheet.panel)
        XCTAssertNil(controller.addStartupTabSheet)
    }

    // MARK: - 任务 3.1：ManagerModel 跨进程实时刷新与未保存草稿保护

    func testManagerModelReloadsOnMatchingScopeAndPreservesUnsavedDrafts() throws {
        let profile = Profile(name: "分屏环境", mode: .persistent)
        try environment.workspace.profiles.insert(profile)

        let model = ManagerModel(workspace: environment.workspace, credentials: InMemoryCredentialStore())
        model.startObservingProfilesSync()
        defer { model.stopObservingProfilesSync() }

        XCTAssertEqual(model.profile(profile.id)?.startupTabs, [])

        // 1. 另一个工作目录的变更通知不应影响当前管理器
        let otherRoot = environment.root.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherWorkspace = SafarierWorkspace(root: otherRoot)
        try environment.workspace.profiles.mutate(id: profile.id) {
            $0.startupTabs.append(StartupTab(url: url("https://first.example.com")))
        }
        ProfilesSyncNotification.post(scope: ProfilesSyncNotification.workspaceScope(for: otherWorkspace.root))
        TestBrowserEnvironment.spin(0.15)
        XCTAssertEqual(model.profile(profile.id)?.startupTabs, [], "其他工作目录的通知不应触发本管理器刷新")

        // 2. 同工作目录的通知应立即触发 reload，同步到模型与未修改的编辑器
        let editor = model.editor(for: try XCTUnwrap(model.profile(profile.id)))
        ProfilesSyncNotification.post(scope: ProfilesSyncNotification.workspaceScope(for: environment.workspace.root))
        TestBrowserEnvironment.spin(0.2)
        XCTAssertEqual(model.profile(profile.id)?.startupTabs.map(\.url), [url("https://first.example.com")])
        XCTAssertEqual(editor.values.startupTabs.map(\.url), ["https://first.example.com"])

        // 3. 管理器中若已有未保存草稿，收到同步通知后保留草稿不覆写
        editor.values.notes = "正在编辑但还没点保存"
        XCTAssertTrue(editor.hasChanges)

        try environment.workspace.profiles.mutate(id: profile.id) {
            $0.startupTabs.append(StartupTab(url: url("https://second.example.com")))
        }
        ProfilesSyncNotification.post(scope: ProfilesSyncNotification.workspaceScope(for: environment.workspace.root))
        TestBrowserEnvironment.spin(0.2)

        XCTAssertEqual(model.profile(profile.id)?.startupTabs.count, 2, "模型侧已同步最新磁盘数据")
        XCTAssertEqual(editor.values.notes, "正在编辑但还没点保存", "未保存草稿不得被覆写")
        XCTAssertEqual(editor.values.startupTabs.count, 1, "未保存编辑器的启动页签草稿保持原样，保存时触发外部变更冲突提示")
    }
}
