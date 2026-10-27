import XCTest
@testable import SafarierCore

private final class RecordingSpawner: ProcessSpawning, @unchecked Sendable {
    struct Call: Equatable {
        var executableURL: URL
        var arguments: [String]
        var environment: [String: String]
        var logURL: URL?
    }
    private(set) var calls: [Call] = []

    func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
        calls.append(Call(executableURL: executableURL, arguments: arguments, environment: environment, logURL: logURL))
        return 4242
    }
}

final class RunnerLauncherTests: XCTestCase {
    func testLaunchPassesSpecAsArgumentsEnvironmentAndPerProfileLog() throws {
        let spawner = RecordingSpawner()
        let exe = URL(fileURLWithPath: "/opt/Safarier")
        let logs = URL(fileURLWithPath: "/tmp/safarier-logs", isDirectory: true)
        let launcher = RunnerLauncher(executableURL: exe, spawner: spawner, logDirectory: logs)
        let spec = RunnerLaunchSpec(profileID: UUID(), languages: ["ja-JP"], timeZoneIdentifier: "Asia/Tokyo")

        let pid = try launcher.launch(spec, baseEnvironment: ["HOME": "/Users/x"])

        XCTAssertEqual(pid, 4242)
        XCTAssertEqual(spawner.calls.count, 1)
        let call = try XCTUnwrap(spawner.calls.first)
        XCTAssertEqual(call.executableURL, exe)
        XCTAssertEqual(call.arguments, spec.arguments())
        XCTAssertEqual(call.environment, ["HOME": "/Users/x", "TZ": "Asia/Tokyo"])
        XCTAssertEqual(call.logURL?.lastPathComponent, "\(spec.profileID.uuidString).log")
    }
}
