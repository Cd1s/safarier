import XCTest
@testable import Safarier

/// 命令行 `--lang` / `--tz` 的取值：proxy / auto 跟随代理，system / none 跟随系统，其它照原样。
@MainActor
final class ManagerCLITests: XCTestCase {
    func testLanguageOption() {
        for raw in ["proxy", "auto", "PROXY"] {
            let option = ManagerCLI.parseLanguageOption(raw)
            XCTAssertTrue(option.follow, raw)
            XCTAssertEqual(option.languages, [], raw)
        }
        for raw in ["system", "none"] {
            let option = ManagerCLI.parseLanguageOption(raw)
            XCTAssertFalse(option.follow, raw)
            XCTAssertEqual(option.languages, [], raw)
        }
        let custom = ManagerCLI.parseLanguageOption("th-TH, th")
        XCTAssertFalse(custom.follow)
        XCTAssertEqual(custom.languages, ["th-TH", "th"])
    }

    func testTimeZoneOption() {
        for raw in ["proxy", "auto"] {
            let option = ManagerCLI.parseTimeZoneOption(raw)
            XCTAssertTrue(option.follow, raw)
            XCTAssertNil(option.identifier, raw)
        }
        for raw in ["system", "none"] {
            let option = ManagerCLI.parseTimeZoneOption(raw)
            XCTAssertFalse(option.follow, raw)
            XCTAssertNil(option.identifier, raw)
        }
        let custom = ManagerCLI.parseTimeZoneOption("Asia/Bangkok")
        XCTAssertFalse(custom.follow)
        XCTAssertEqual(custom.identifier, "Asia/Bangkok")
    }
}
