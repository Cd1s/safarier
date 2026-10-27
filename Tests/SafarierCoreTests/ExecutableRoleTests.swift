import XCTest
@testable import SafarierCore

final class ExecutableRoleTests: XCTestCase {
    func testNoArgumentsOpensManagerGUI() {
        XCTAssertEqual(ExecutableRole.resolve([]), .manager)
    }

    func testLaunchServicesAndUserDefaultsArgumentsStillOpenManagerGUI() {
        XCTAssertEqual(ExecutableRole.resolve(["-psn_0_123456"]), .manager)
        XCTAssertEqual(ExecutableRole.resolve(["-NSDocumentRevisionsDebugMode", "YES"]), .manager)
        XCTAssertEqual(ExecutableRole.resolve(["-psn_0_1", "-AppleLanguages", "(en)"]), .manager)
    }

    func testRunSubcommandIsRunner() {
        XCTAssertEqual(ExecutableRole.resolve(["run", "--profile", UUID().uuidString]), .runner)
        XCTAssertEqual(ExecutableRole.resolve(RunnerLaunchSpec(profileID: UUID(), languages: ["en"]).arguments()), .runner)
    }

    func testSubcommandsStayOnCommandLine() {
        XCTAssertEqual(ExecutableRole.resolve(["profile", "list"]), .cli)
        XCTAssertEqual(ExecutableRole.resolve(["sub", "update"]), .cli)
        XCTAssertEqual(ExecutableRole.resolve(["launch", UUID().uuidString]), .cli)
        XCTAssertEqual(ExecutableRole.resolve(["help"]), .cli)
        XCTAssertEqual(ExecutableRole.resolve(["--help"]), .cli)
        XCTAssertEqual(ExecutableRole.resolve(["-psn_0_1", "profile", "list"]), .cli)
    }
}
