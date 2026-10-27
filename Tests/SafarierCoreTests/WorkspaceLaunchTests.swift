import XCTest
@testable import SafarierCore

private final class RecordingSpawner: ProcessSpawning, @unchecked Sendable {
    private(set) var calls: [(arguments: [String], environment: [String: String], logURL: URL?)] = []

    func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
        calls.append((arguments, environment, logURL))
        return 777
    }
}

final class WorkspaceLaunchTests: XCTestCase {
    private var workspace: SafarierWorkspace!

    override func setUpWithError() throws {
        workspace = SafarierWorkspace(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("safarier-workspace-\(UUID().uuidString)", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace.root)
    }

    private func launcher(_ spawner: RecordingSpawner) -> RunnerLauncher {
        RunnerLauncher(executableURL: URL(fileURLWithPath: "/opt/Safarier"), spawner: spawner, logDirectory: workspace.logsDirectory)
    }

    func testLaunchUsesProfileSettingsAndPerProfileLog() throws {
        let profile = Profile(
            name: "us",
            mode: .persistent,
            languages: ["en-US", "en"],
            timeZoneIdentifier: "America/Los_Angeles",
            startURL: URL(string: "https://example.com")
        )
        let spawner = RecordingSpawner()

        let pid = try workspace.launch(profile, launcher: launcher(spawner))

        XCTAssertEqual(pid, 777)
        let call = try XCTUnwrap(spawner.calls.first)
        let spec = try RunnerLaunchSpec.parse(call.arguments, environment: call.environment)
        XCTAssertEqual(spec, workspace.runnerSpec(for: profile))
        XCTAssertEqual(spec.startURL, profile.startURL)
        XCTAssertEqual(spec.languages, ["en-US", "en"])
        XCTAssertEqual(call.environment["TZ"], "America/Los_Angeles")
        XCTAssertEqual(call.logURL, workspace.runnerLogURL(for: profile.id))
    }

    func testURLAndSPIOverrideOnlyAffectThisRun() throws {
        let profile = Profile(name: "a", mode: .ephemeral, startURL: URL(string: "https://example.com"), spi: .all)
        let spawner = RecordingSpawner()

        try workspace.launch(profile, url: URL(string: "https://example.org"), spiOverride: [], launcher: launcher(spawner))

        let spec = try RunnerLaunchSpec.parse(try XCTUnwrap(spawner.calls.first).arguments)
        XCTAssertEqual(spec.startURL, URL(string: "https://example.org"))
        XCTAssertEqual(spec.spiOverride, [])
    }

    func testRefusesToLaunchWhileRunnerHoldsLock() throws {
        let profile = Profile(name: "a", mode: .persistent)
        let lock = try ProfileLock.acquire(profileID: profile.id, in: workspace.locksDirectory)
        let spawner = RecordingSpawner()

        XCTAssertEqual(workspace.runnerPID(profile.id), getpid())
        XCTAssertThrowsError(try workspace.launch(profile, launcher: launcher(spawner))) {
            XCTAssertEqual($0 as? WorkspaceError, .alreadyRunning(profile.id))
        }
        XCTAssertTrue(spawner.calls.isEmpty)

        lock.release()
        XCTAssertNil(workspace.runnerPID(profile.id))
        XCTAssertNoThrow(try workspace.launch(profile, launcher: launcher(spawner)))
    }

    func testProcessExitFailureClassification() {
        XCTAssertFalse(ProcessExit(pid: 1, status: 0, uncaughtSignal: false).isFailure)
        XCTAssertTrue(ProcessExit(pid: 1, status: 1, uncaughtSignal: false).isFailure)
        XCTAssertFalse(ProcessExit(pid: 1, status: SIGTERM, uncaughtSignal: true).isFailure)
        XCTAssertFalse(ProcessExit(pid: 1, status: SIGKILL, uncaughtSignal: true).isFailure)
        XCTAssertTrue(ProcessExit(pid: 1, status: SIGSEGV, uncaughtSignal: true).isFailure)
    }

    func testFoundationSpawnerReportsExitStatus() throws {
        let exited = expectation(description: "exit")
        nonisolated(unsafe) var result: ProcessExit?
        let spawner = FoundationProcessSpawner { exit in
            result = exit
            exited.fulfill()
        }

        let pid = try spawner.spawn(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], environment: [:], logURL: nil)

        wait(for: [exited], timeout: 10)
        XCTAssertEqual(result, ProcessExit(pid: pid, status: 3, uncaughtSignal: false))
    }
}
