import AppKit
import SwiftUI
import XCTest
import SafarierCore
import SafarierNetwork
@testable import Safarier

@MainActor
final class InlineProfileEditorTests: XCTestCase {
    private var root: URL!
    private var workspace: SafarierWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-editor-\(UUID())")
        workspace = SafarierWorkspace(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func insert(_ name: String) throws -> Profile {
        let profile = Profile(name: name, mode: .persistent)
        try workspace.profiles.insert(profile)
        return profile
    }

    func testDraftSurvivesSelectionAndSavesOnlyItsProfile() async throws {
        let first = try insert("First")
        let second = try insert("Second")
        let model = ManagerModel(workspace: workspace)
        let editor = model.editor(for: first)
        editor.values.name = "Renamed"
        editor.values.languageSource = .custom
        editor.values.languages = "en-US, en"
        editor.values.startupTabs = [StartupTabDraft(url: "example.com")]
        editor.values.notes = "A note"
        model.selection = .profile(second.id)
        XCTAssertTrue(model.editor(for: first) === editor)
        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(try workspace.profiles.record(id: first.id), first, "草稿不自动写盘")
        let saved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertTrue(saved)
        let record = try XCTUnwrap(workspace.profiles.record(id: first.id))
        XCTAssertEqual(record.name, "Renamed")
        XCTAssertEqual(record.languages, ["en-US", "en"])
        XCTAssertEqual(record.startURL?.absoluteString, "https://example.com")
        XCTAssertEqual(record.notes, "A note")
        XCTAssertEqual(record.id, first.id)
        XCTAssertEqual(record.mode, first.mode)
        XCTAssertEqual(record.createdAt, first.createdAt)
        XCTAssertEqual(model.selection, .profile(second.id), "保存不把用户拉回原来的环境")
        XCTAssertEqual(try workspace.profiles.record(id: second.id), second)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertFalse(editor.isSaving)
    }

    func testInvalidInputStaysInDraftAndResetUsesLatestRecord() async throws {
        let original = try insert("Original")
        let model = ManagerModel(workspace: workspace)
        let editor = model.editor(for: original)
        editor.values.languageSource = .custom
        editor.values.languages = " , "
        let saved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertFalse(saved)
        XCTAssertNotNil(editor.errorText)
        XCTAssertEqual(editor.values.languages, " , ")
        XCTAssertEqual(try workspace.profiles.record(id: original.id), original)
        XCTAssertNil(model.duplicate(original), "不复制未保存草稿背后的旧设置")

        var external = original
        external.name = "External"
        try workspace.profiles.update(external)
        model.reload()
        XCTAssertEqual(editor.values.languages, " , ", "重新读取不覆盖未完成输入")
        editor.reset(to: try XCTUnwrap(model.profile(original.id)))
        XCTAssertEqual(editor.values.name, "External")
        XCTAssertFalse(editor.hasChanges)
        XCTAssertNil(editor.errorText)
    }

    func testExternalEditDuringValidationIsNotOverwritten() async throws {
        let original = try insert("Original")
        let model = ManagerModel(workspace: workspace)
        let editor = model.editor(for: original)
        editor.values.outboundKind = .custom
        editor.values.customJSON = CustomOutbound.defaultJSON
        editor.values.name = "Draft"
        let validator = root.appendingPathComponent("validator")
        try Data("#!/bin/sh\n/bin/sleep 0.2\nexit 0\n".utf8).write(to: validator)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: validator.path)
        let saving = Task { await editor.save(using: model, selectSavedProfile: false, executableURL: validator) }
        while !editor.isSaving { await Task.yield() }
        var external = original
        external.notes = "Externally changed"
        try workspace.profiles.update(external)
        let saved = await saving.value
        XCTAssertFalse(saved)
        XCTAssertEqual(try workspace.profiles.record(id: original.id), external)
        XCTAssertEqual(editor.values.name, "Draft")
        XCTAssertEqual(model.profile(original.id), external)
        XCTAssertNotNil(editor.errorText)
        XCTAssertFalse(editor.isSaving)
    }

    func testCleanDraftTracksReloadAndDeletedProfileCannotBeResurrected() async throws {
        let original = try insert("Original")
        let model = ManagerModel(workspace: workspace)
        let editor = model.editor(for: original)
        var external = original
        external.name = "Updated"
        try workspace.profiles.update(external)
        model.reload()
        XCTAssertEqual(editor.values.name, "Updated")
        XCTAssertFalse(editor.hasChanges)
        editor.values.name = "Draft"
        try workspace.profiles.delete(id: original.id)
        let saved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertFalse(saved)
        XCTAssertNil(try workspace.profiles.record(id: original.id))
        XCTAssertNil(model.profile(original.id))
    }

    func testCreationAndProxyValidationKeepExistingContracts() async throws {
        let model = ManagerModel(workspace: workspace)
        let editor = ProfileEditorState(original: nil)
        editor.values.name = "New"
        editor.values.mode = .ephemeral
        editor.values.outboundKind = .proxy
        let rejected = await editor.save(using: model, selectSavedProfile: true)
        XCTAssertFalse(rejected)
        XCTAssertTrue(try workspace.profiles.all().isEmpty)
        editor.values.outboundKind = .direct
        let saved = await editor.save(using: model, selectSavedProfile: true)
        XCTAssertTrue(saved)
        let profile = try XCTUnwrap(workspace.profiles.all().first)
        XCTAssertEqual(profile.mode, .ephemeral)
        XCTAssertEqual(model.selection, .profile(profile.id))
    }

    func testInlineEditPreservesChainedProxyAndConnectionPath() async throws {
        let entry = ProxySettings(name: "Entry", kind: .socks5, host: "192.0.2.1", port: 1080)
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "192.0.2.2", port: 8080, upstream: .proxy(entry.id))
        try workspace.insertProxy(entry)
        try workspace.insertProxy(exit)
        let profile = Profile(name: "Chained", mode: .ephemeral, proxyID: exit.id)
        try workspace.profiles.insert(profile)
        let model = ManagerModel(workspace: workspace, credentials: InMemoryCredentialStore())
        let editor = model.editor(for: profile)
        XCTAssertEqual(editor.values.outboundKind, .proxy)
        let selected = try XCTUnwrap(editor.values.proxyID.flatMap(model.proxy))
        XCTAssertEqual(selected.upstream, .proxy(entry.id))
        XCTAssertEqual(model.connectionPath(selected), "Entry → Exit → 网站")

        editor.values.notes = "Edited inline"
        let saved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertTrue(saved)
        let record = try XCTUnwrap(workspace.profiles.record(id: profile.id))
        XCTAssertEqual(record.proxyID, exit.id)
        XCTAssertEqual(record.notes, "Edited inline")
        XCTAssertEqual(try workspace.proxies.record(id: exit.id), exit)
        XCTAssertFalse(editor.hasChanges)
    }

    func testStartupTabsSaveOrderPauseResetAndDeletion() async throws {
        let original = try insert("Startup")
        let model = ManagerModel(workspace: workspace)
        let editor = model.editor(for: original)
        let first = StartupTabDraft(url: "example.com/first")
        let paused = StartupTabDraft(url: "example.com/paused", isEnabled: false)
        let third = StartupTabDraft(url: "example.com/third")
        editor.values.startupTabs = [third, paused, first]
        XCTAssertTrue(editor.hasChanges)
        let saved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertTrue(saved)
        let record = try XCTUnwrap(workspace.profiles.record(id: original.id))
        XCTAssertEqual(record.startupTabs.map(\.id), [third.id, paused.id, first.id])
        XCTAssertEqual(record.startupTabs.map(\.isEnabled), [true, false, true])
        XCTAssertEqual(record.startupURLs.map(\.absoluteString), ["https://example.com/third", "https://example.com/first"])
        XCTAssertFalse(editor.hasChanges)
        editor.values.startupTabs.removeAll()
        editor.reset(to: record)
        XCTAssertEqual(editor.values.startupTabs.map(\.id), [third.id, paused.id, first.id])
        for index in editor.values.startupTabs.indices { editor.values.startupTabs[index].isEnabled = false }
        let pausedSaved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertTrue(pausedSaved)
        XCTAssertNil(try workspace.profiles.record(id: original.id)?.startURL)
        editor.values.startupTabs.removeAll()
        let cleared = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertTrue(cleared)
        XCTAssertEqual(try workspace.profiles.record(id: original.id)?.startupTabs, [])
    }

    func testInvalidPausedStartupTabKeepsDraftAndReportsRow() async throws {
        let original = try insert("Invalid startup")
        let model = ManagerModel(workspace: workspace)
        let editor = model.editor(for: original)
        editor.values.startupTabs = [StartupTabDraft(url: "example.com"), StartupTabDraft(url: "not a URL", isEnabled: false)]
        let saved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertFalse(saved)
        XCTAssertTrue(editor.errorText?.contains("2") == true)
        XCTAssertEqual(editor.values.startupTabs[1].url, "not a URL")
        XCTAssertEqual(try workspace.profiles.record(id: original.id), original)
        editor.values.startupTabs[1].url = ""
        let emptySaved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertFalse(emptySaved, "新增的空行应提示填写或删除，不能静默丢弃")
    }

    func testStartupTabsSectionOrderPromoteReorderAndInlineValidation() {
        let first = StartupTabDraft(url: "https://example.com/1", isEnabled: false)
        let second = StartupTabDraft(url: "https://example.com/2", isEnabled: true)
        let third = StartupTabDraft(url: "https://example.com/3", isEnabled: true)
        var tabs = [first, second, third]

        XCTAssertEqual(StartupTabsSection.firstEnabledID(in: tabs), second.id)
        XCTAssertNil(StartupTabsSection.enabledOrder(of: first.id, in: tabs))
        XCTAssertEqual(StartupTabsSection.enabledOrder(of: second.id, in: tabs), 1)
        XCTAssertEqual(StartupTabsSection.enabledOrder(of: third.id, in: tabs), 2)

        StartupTabsSection.move(&tabs, id: third.id, by: -1)
        XCTAssertEqual(tabs.map(\.id), [first.id, third.id, second.id])
        StartupTabsSection.move(&tabs, id: first.id, by: -1)
        XCTAssertEqual(tabs.map(\.id), [first.id, third.id, second.id], "越界上移不应改变顺序")

        StartupTabsSection.reorder(&tabs, moving: second.id, to: first.id)
        XCTAssertEqual(tabs.map(\.id), [second.id, first.id, third.id])

        StartupTabsSection.moveToTop(&tabs, id: first.id)
        XCTAssertEqual(tabs.first?.id, first.id)
        XCTAssertEqual(tabs.first?.isEnabled, true, "设为首个主页时应同时启用该页签")
        XCTAssertEqual(StartupTabsSection.firstEnabledID(in: tabs), first.id)

        let typingInvalid = StartupTabDraft(url: "https://")
        XCTAssertFalse(
            StartupTabsSection.shouldShowInlineError(tab: typingInvalid, focusedID: typingInvalid.id, touchedIDs: [typingInvalid.id], showsAll: false),
            "正在输入且未失焦时不应中途报错"
        )
        XCTAssertTrue(
            StartupTabsSection.shouldShowInlineError(tab: typingInvalid, focusedID: nil, touchedIDs: [typingInvalid.id], showsAll: false),
            "失焦后非空无效网址应显示行内提示"
        )
        let emptyPending = StartupTabDraft(url: "   ")
        XCTAssertFalse(
            StartupTabsSection.shouldShowInlineError(tab: emptyPending, focusedID: nil, touchedIDs: [emptyPending.id], pendingIDs: [emptyPending.id], showsAll: false),
            "未提交前新增空白行不主动标红"
        )
        XCTAssertTrue(
            StartupTabsSection.shouldShowInlineError(tab: emptyPending, focusedID: nil, touchedIDs: [emptyPending.id], pendingIDs: [], showsAll: false),
            "已有页签被清空后失焦应标红提示"
        )
        XCTAssertTrue(
            StartupTabsSection.shouldShowInlineError(tab: emptyPending, focusedID: emptyPending.id, touchedIDs: [], pendingIDs: [emptyPending.id], showsAll: true),
            "触发保存校验时空白行应标红提示"
        )
        XCTAssertFalse(
            StartupTabsSection.shouldShowInlineError(tab: second, focusedID: nil, touchedIDs: [second.id], showsAll: true),
            "合法网址任何时候都不应显示错误"
        )

        var pendingIDs: Set<UUID> = []
        var touchedIDs: Set<UUID> = []
        let addedID = StartupTabsSection.prepareAddTab(&tabs, pendingIDs: &pendingIDs)
        XCTAssertEqual(tabs.count, 4)
        XCTAssertEqual(
            StartupTabsSection.prepareAddTab(&tabs, pendingIDs: &pendingIDs),
            addedID,
            "已有未填写的新增空白行时应复用，不再重复堆叠空行"
        )
        XCTAssertEqual(tabs.count, 4)

        tabs[3].url = "   "
        XCTAssertTrue(
            StartupTabsSection.handleBlur(&tabs, pendingIDs: &pendingIDs, touchedIDs: &touchedIDs, blurredID: addedID),
            "未填地址的新增页签失焦时应自动撤销新增"
        )
        XCTAssertEqual(tabs.count, 3)
        XCTAssertFalse(pendingIDs.contains(addedID))

        let filledID = StartupTabsSection.prepareAddTab(&tabs, pendingIDs: &pendingIDs)
        tabs[3].url = "example.com/new"
        XCTAssertFalse(
            StartupTabsSection.handleBlur(&tabs, pendingIDs: &pendingIDs, touchedIDs: &touchedIDs, blurredID: filledID),
            "已填写地址的新增页签失焦时应保留"
        )
        XCTAssertEqual(tabs.count, 4)
        XCTAssertTrue(touchedIDs.contains(filledID))
        tabs.removeLast()

        let snapshot = StartupTabsSection.DeletedTabSnapshot(tab: third, index: 2, remainingIDs: [first.id, second.id])
        tabs.removeAll { $0.id == third.id }
        XCTAssertTrue(StartupTabsSection.restoreDeleted(&tabs, from: snapshot))
        XCTAssertEqual(tabs.map(\.id), [first.id, second.id, third.id])
        XCTAssertFalse(
            StartupTabsSection.restoreDeleted(&tabs, from: snapshot),
            "若该页签标识已存在（例如外部还原后），撤销删除不得插入重复项"
        )
        XCTAssertEqual(tabs.count, 3)

        // 回归：删除末行后，残留的 NSTextField 绑定回读或写入绝不能触发数组越界崩溃。
        let tabsBinding = Binding(get: { tabs }, set: { tabs = $0 })
        let lastTab = tabs[2]
        let safeURL = StartupTabsSection.urlBinding(for: lastTab.id, fallback: lastTab.url, in: tabsBinding)
        let safeEnabled = StartupTabsSection.enabledBinding(for: lastTab.id, fallback: lastTab.isEnabled, in: tabsBinding)
        tabs.removeLast()
        XCTAssertEqual(safeURL.wrappedValue, lastTab.url)
        safeURL.wrappedValue = "https://should-not-crash.example.com"
        XCTAssertEqual(safeEnabled.wrappedValue, lastTab.isEnabled)
        safeEnabled.wrappedValue = false
        XCTAssertEqual(tabs.count, 2, "写入已删除行的安全绑定不应改动剩余项")
    }

    @MainActor
    func testStartupTabsOutsideClickResignDecision() {
        let container = NSView()
        let activeField = NSTextField(string: "")
        activeField.isEditable = true
        let fieldEditor = NSTextView()
        fieldEditor.isEditable = true
        activeField.addSubview(fieldEditor)

        let staticLabel = NSTextField(labelWithString: "静态标签")
        let otherInput = NSTextField(string: "")
        otherInput.isEditable = true
        let emptyBackground = NSView()

        container.addSubview(activeField)
        container.addSubview(staticLabel)
        container.addSubview(otherInput)
        container.addSubview(emptyBackground)

        XCTAssertFalse(
            StartupTabsSection.shouldResignFocusOnClick(activeField: activeField, fieldEditor: fieldEditor, hitView: activeField),
            "点击当前输入框自身不应失焦"
        )
        XCTAssertFalse(
            StartupTabsSection.shouldResignFocusOnClick(activeField: activeField, fieldEditor: fieldEditor, hitView: fieldEditor),
            "点击当前字段编辑器不应失焦"
        )
        XCTAssertFalse(
            StartupTabsSection.shouldResignFocusOnClick(activeField: activeField, fieldEditor: fieldEditor, hitView: otherInput),
            "点击另一个可编辑输入框应交由 AppKit 转移焦点"
        )
        XCTAssertTrue(
            StartupTabsSection.shouldResignFocusOnClick(activeField: activeField, fieldEditor: fieldEditor, hitView: emptyBackground),
            "点击表单空白区域应主动结束编辑"
        )
        XCTAssertTrue(
            StartupTabsSection.shouldResignFocusOnClick(activeField: activeField, fieldEditor: fieldEditor, hitView: staticLabel),
            "点击非可编辑静态文本标签也应主动结束编辑"
        )
    }

    func testInlineEditorSavesBypassSystemProxyAndClearsOnProxySwitch() async throws {
        let original = try insert("LocalDirect")
        let proxy = ProxySettings(name: "SOCKS", kind: .socks5, host: "192.0.2.1", port: 1080)
        try workspace.proxies.insert(proxy)

        let model = ManagerModel(workspace: workspace)
        let editor = model.editor(for: original)
        XCTAssertFalse(editor.values.bypassSystemProxy)
        editor.values.bypassSystemProxy = true
        XCTAssertTrue(editor.hasChanges)

        let saved = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertTrue(saved)
        let stored = try XCTUnwrap(workspace.profiles.record(id: original.id))
        XCTAssertTrue(stored.bypassSystemProxy)
        if case .localDirect = model.proxyBinding(for: stored) {
            XCTAssertEqual(DisplayText.proxyName(.localDirect), "本机网络")
        } else {
            XCTFail("开启绕过系统代理后应展示为 localDirect")
        }

        editor.values.outboundKind = .proxy
        editor.values.proxyID = proxy.id
        let savedProxy = await editor.save(using: model, selectSavedProfile: false)
        XCTAssertTrue(savedProxy)
        let afterProxy = try XCTUnwrap(workspace.profiles.record(id: original.id))
        XCTAssertEqual(afterProxy.proxyID, proxy.id)
        XCTAssertFalse(afterProxy.bypassSystemProxy, "切换到独立代理后应自动关闭本机网络直连标志")
    }
}
