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
        editor.values.startURL = "example.com"
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
}
