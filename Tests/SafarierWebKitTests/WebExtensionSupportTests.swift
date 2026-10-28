import XCTest
import WebKit
import SafarierCore
@testable import SafarierWebKit

@MainActor
final class WebExtensionSupportTests: XCTestCase {
    func testAttachLoadsEnabledManifestOnSupportedRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webextension-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Runtime Test","version":"1.0","content_scripts":[{"matches":["https://example.com/*"],"js":["content.js"]}]}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        try Data("void 0;".utf8).write(to: source.appendingPathComponent("content.js"))

        let workspace = SafarierWorkspace(root: root.appendingPathComponent("store", isDirectory: true))
        let profile = Profile(name: "extensions", mode: .ephemeral)
        let record = try workspace.importExtension(from: source)
        try workspace.enableExtension(record.id, for: profile.id)
        let configuration = WKWebViewConfiguration()
        let mount = WebExtensionSupport.attach(profile: profile, workspace: workspace, to: configuration)
        if #available(macOS 15.4, *) {
            let runtime = try XCTUnwrap(mount.runtime)
            XCTAssertNotNil(configuration.webExtensionController)
            await runtime.waitUntilSettled()
            XCTAssertEqual(runtime.states[record.id], .loaded, "native extension loading failed: \(String(describing: runtime.states[record.id]))")
        } else {
            XCTAssertNil(mount.runtime)
            XCTAssertEqual(mount.state.name, "unavailable")
        }
    }

    func testAttachWithoutEnabledRecordsKeepsControllerReadyForLaterInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webextension-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let configuration = WKWebViewConfiguration()
        let mount = WebExtensionSupport.attach(profile: Profile(name: "empty", mode: .ephemeral), workspace: workspace, to: configuration)
        XCTAssertNotNil(mount.runtime)
        XCTAssertEqual(mount.state.name, "notRequested")
        if #available(macOS 15.4, *) { XCTAssertNotNil(configuration.webExtensionController) }
    }
}
