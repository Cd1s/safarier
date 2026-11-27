import XCTest
import SafarierCore
@testable import Safarier

@MainActor
final class StartupTabsCLITests: XCTestCase {
    private var root: URL!
    private var previousHome: String?
    private var workspace: SafarierWorkspace { SafarierWorkspace(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("startup-cli-\(UUID())")
        previousHome = ProcessInfo.processInfo.environment["SAFARIER_HOME"]
        setenv("SAFARIER_HOME", root.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("SAFARIER_HOME", previousHome, 1) } else { unsetenv("SAFARIER_HOME") }
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateReplacePreserveAndClearStartupTabs() throws {
        XCTAssertEqual(ManagerCLI.run(["profile", "create", "--name", "Startup", "--url", "https://example.com/first", "--url", "https://example.com/second"]), 0)
        var profile = try XCTUnwrap(workspace.profiles.all().first)
        XCTAssertEqual(profile.startupURLs.map(\.absoluteString), ["https://example.com/first", "https://example.com/second"])
        profile.startupTabs[1].isEnabled = false
        try workspace.profiles.update(profile)
        XCTAssertEqual(ManagerCLI.run(["profile", "update", profile.id.uuidString, "--notes", "Edited"]), 0)
        XCTAssertEqual(try workspace.profiles.record(id: profile.id)?.startupTabs, profile.startupTabs)
        XCTAssertEqual(ManagerCLI.run(["profile", "update", profile.id.uuidString, "--url", "https://example.com/replaced"]), 0)
        XCTAssertEqual(try workspace.profiles.record(id: profile.id)?.startupURLs.map(\.absoluteString), ["https://example.com/replaced"])
        XCTAssertEqual(ManagerCLI.run(["profile", "update", profile.id.uuidString, "--url", "none"]), 0)
        XCTAssertEqual(try workspace.profiles.record(id: profile.id)?.startupTabs, [])
    }

    func testInvalidURLDoesNotReplaceSavedStartupTabs() throws {
        let profile = Profile(name: "Valid", mode: .persistent, startURL: URL(string: "https://example.com"))
        try workspace.profiles.insert(profile)
        XCTAssertEqual(ManagerCLI.run(["profile", "update", profile.id.uuidString, "--url", "https://"]), 64)
        XCTAssertEqual(ManagerCLI.run(["profile", "update", profile.id.uuidString, "--url", "ftp://example.com"]), 64)
        XCTAssertEqual(try workspace.profiles.record(id: profile.id), profile)
    }

    func testSchemelessURLIsNormalizedInCLI() throws {
        XCTAssertEqual(ManagerCLI.run(["profile", "create", "--name", "Norm", "--url", "example.com/first"]), 0)
        let profile = try XCTUnwrap(workspace.profiles.all().first)
        XCTAssertEqual(profile.startupURLs.map(\.absoluteString), ["https://example.com/first"])
    }

    func testRepeatedOptionsRetainExistingLastValueSemantics() throws {
        let args = try ParsedArguments(["--name", "First", "--name", "Last", "--spi", "none", "--spi", "all"])
        XCTAssertEqual(args.value("--name"), "Last")
        XCTAssertEqual(try args.required("--name"), "Last")
        XCTAssertEqual(try args.spi(), .all)
    }
}
