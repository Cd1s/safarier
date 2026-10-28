import XCTest
import SafarierCore
import SafarierNetwork
@testable import Safarier

@MainActor
final class CustomOutboundEditorTests: XCTestCase {
    func testManualFormRoundTripsAuthenticationAndKeepsAdvancedFieldsInJSONEditor() throws {
        var draft = ManualProxyDraft()
        draft.kind = .httpConnect
        draft.username = "user"
        draft.password = "secret"
        let decoded = try XCTUnwrap(ManualProxyDraft(json: draft.json()))
        XCTAssertEqual(decoded.kind, draft.kind)
        XCTAssertEqual(decoded.password, draft.password)
        let advanced = #"{"type":"http","server":"proxy.example","server_port":443,"tls":{"enabled":true}}"#
        XCTAssertNil(ManualProxyDraft(json: advanced), "高级字段不能被表单静默丢弃")
    }

    func testFailedCheckPreservesSavedProfileAndSuccessfulCheckSurvivesReloadAndCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let original = Profile(name: "Original", mode: .ephemeral)
        try workspace.profiles.insert(original)
        let model = ManagerModel(workspace: workspace)
        var edited = original
        edited.customOutboundJSON = CustomOutbound.defaultJSON
        edited.name = "Edited"
        do {
            try await model.saveValidated(edited, isNew: false, executableURL: URL(fileURLWithPath: "/usr/bin/false"))
            XCTFail("校验失败应该阻止保存")
        } catch {
            XCTAssertEqual(try workspace.profiles.record(id: original.id), original)
        }
        guard let executable = SingboxProcessManager.locateExecutable() else { throw XCTSkip("本机没有 sing-box") }
        try await model.saveValidated(edited, isNew: false, executableURL: executable)
        let saved = try XCTUnwrap(workspace.profiles.record(id: original.id))
        XCTAssertEqual(saved.name, "Edited")
        XCTAssertNotNil(saved.customOutboundJSON)
        if case .custom = model.proxyBinding(for: saved) {} else { XCTFail("自定义出站不能显示为直连") }
        let copy = try XCTUnwrap(model.duplicate(saved))
        XCTAssertEqual(copy.customOutboundJSON, saved.customOutboundJSON)
        XCTAssertNotEqual(copy.id, saved.id)
        let previous = ProcessInfo.processInfo.environment["SAFARIER_HOME"]
        setenv("SAFARIER_HOME", root.path, 1)
        defer {
            if let previous { setenv("SAFARIER_HOME", previous, 1) } else { unsetenv("SAFARIER_HOME") }
        }
        XCTAssertEqual(ManagerCLI.run(["profile", "update", saved.id.uuidString, "--proxy", "none"]), 0)
        XCTAssertNil(try workspace.profiles.record(id: saved.id)?.customOutboundJSON)
    }
}
