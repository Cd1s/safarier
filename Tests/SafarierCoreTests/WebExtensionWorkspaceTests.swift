import XCTest
@testable import SafarierCore

final class WebExtensionWorkspaceTests: XCTestCase {
    func testImportEnableDisableAndRemoveUnpackedExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-workspace-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Example Tools","version":"1.2.3","content_scripts":[{"matches":["https://example.com/*"],"js":["content.js"]}]}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        try Data("console.log('example');".utf8).write(to: source.appendingPathComponent("content.js"))

        let workspace = SafarierWorkspace(root: root.appendingPathComponent("store", isDirectory: true))
        let profileID = UUID()
        let record = try workspace.importExtension(from: source)
        XCTAssertEqual(record.name, "Example Tools")
        XCTAssertEqual(record.version, "1.2.3")
        XCTAssertEqual(record.manifestVersion, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.extensionsDirectory.appendingPathComponent(record.id.uuidString).appendingPathComponent("manifest.json").path))
        XCTAssertTrue(try workspace.enabledExtensions(for: profileID).isEmpty)

        try workspace.enableExtension(record.id, for: profileID)
        XCTAssertEqual(try workspace.enabledExtensions(for: profileID), [record.withProfile(profileID)])
        try workspace.disableExtension(record.id, for: profileID)
        XCTAssertTrue(try workspace.enabledExtensions(for: profileID).isEmpty)
        XCTAssertEqual(try workspace.removeExtension(name: "example tools"), record)
        XCTAssertTrue(try workspace.extensionRecords().isEmpty)
    }

    func testImportAppexResourcesAndRejectUnsupportedManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-appex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Demo.appex/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":2,"name":"App Extension","version":"1"}"#.utf8).write(to: resources.appendingPathComponent("manifest.json"))
        let workspace = SafarierWorkspace(root: root.appendingPathComponent("store", isDirectory: true))
        let record = try workspace.importExtension(from: root.appendingPathComponent("Demo.appex"))
        XCTAssertEqual(record.manifestVersion, 2)

        let bad = root.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":1,"name":"Old","version":"1"}"#.utf8).write(to: bad.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try workspace.importExtension(from: bad)) { error in
            guard case WorkspaceError.unsupportedExtensionManifestVersion(1) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

private extension SafarierExtensionRecord {
    func withProfile(_ profileID: UUID) -> SafarierExtensionRecord {
        var copy = self
        copy.enabledProfileIDs.insert(profileID)
        return copy
    }
}
