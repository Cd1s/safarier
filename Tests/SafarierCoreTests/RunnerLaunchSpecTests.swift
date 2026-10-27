import XCTest
@testable import SafarierCore

final class RunnerLaunchSpecTests: XCTestCase {
    private let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    func testRoundTripThroughArgumentsAndEnvironment() throws {
        let spec = RunnerLaunchSpec(
            profileID: id,
            startURL: URL(string: "https://example.com/a?b=1"),
            languages: ["en-US", "en"],
            timeZoneIdentifier: "America/Los_Angeles",
            probe: true
        )
        let env = spec.environment(inheriting: ["PATH": "/usr/bin", "TZ": "Asia/Shanghai"])
        XCTAssertEqual(env["TZ"], "America/Los_Angeles")
        XCTAssertEqual(env["PATH"], "/usr/bin")

        let parsed = try RunnerLaunchSpec.parse(spec.arguments(), environment: env)
        XCTAssertEqual(parsed, spec)
    }

    /// 父进程残留的跟随代理结果（SAFARIER_GEO_*）不带进新的 Runner，其它变量照常继承。
    func testEnvironmentDropsStaleGeoVariables() {
        let env = RunnerLaunchSpec(profileID: id).environment(inheriting: [
            "PATH": "/usr/bin", "SAFARIER_HOME": "/tmp/h",
            "SAFARIER_GEO_RELAUNCHED": "1", "SAFARIER_GEO_COUNTRY": "JP", "SAFARIER_GEO_LANGUAGES": "ja-JP", "SAFARIER_GEO_TIMEZONE": "Asia/Tokyo",
        ])
        XCTAssertEqual(env, ["PATH": "/usr/bin", "SAFARIER_HOME": "/tmp/h"])
    }

    func testMinimalArgumentsAndInheritedTZIsDropped() throws {
        let spec = RunnerLaunchSpec(profileID: id)
        XCTAssertEqual(spec.arguments(), ["run", "--profile", id.uuidString])
        XCTAssertNil(spec.environment(inheriting: ["TZ": "Asia/Shanghai"])["TZ"])
        XCTAssertEqual(try RunnerLaunchSpec.parse(spec.arguments()), spec)
    }

    func testLanguagesUseOldStylePlistArray() throws {
        let args = RunnerLaunchSpec(profileID: id, languages: ["de-DE", "de"]).arguments()
        XCTAssertEqual(Array(args.suffix(2)), ["-AppleLanguages", "(\"de-DE\", \"de\")"])

        let thai = RunnerLaunchSpec(profileID: id, languages: ["th-TH", "th"])
        XCTAssertEqual(Array(thai.arguments().suffix(2)), ["-AppleLanguages", "(\"th-TH\", \"th\")"])
        XCTAssertEqual(try RunnerLaunchSpec.parse(thai.arguments()).languages, ["th-TH", "th"])
    }

    /// 跟随代理语言：execv 重启前把 -AppleLanguages 换成查到的语言，其它参数原样保留。
    func testReplacingAppleLanguages() throws {
        let original = RunnerLaunchSpec(profileID: id, startURL: URL(string: "https://example.com"), languages: ["zh-CN", "zh"]).arguments()
        let replaced = RunnerLaunchSpec.replacingAppleLanguages(["ja-JP", "ja"], in: original)
        XCTAssertEqual(replaced.filter { $0 == "-AppleLanguages" }.count, 1)
        XCTAssertEqual(Array(replaced.suffix(2)), ["-AppleLanguages", "(\"ja-JP\", \"ja\")"])
        let parsed = try RunnerLaunchSpec.parse(replaced)
        XCTAssertEqual(parsed.profileID, id)
        XCTAssertEqual(parsed.startURL, URL(string: "https://example.com"))
        XCTAssertEqual(parsed.languages, ["ja-JP", "ja"])

        // 原来没有 -AppleLanguages 时直接追加。
        let bare = RunnerLaunchSpec(profileID: id).arguments()
        XCTAssertEqual(RunnerLaunchSpec.replacingAppleLanguages(["en-US"], in: bare), bare + ["-AppleLanguages", "(\"en-US\")"])
    }

    func testIgnoresUserDefaultsArgumentsInjectedByTools() throws {
        let parsed = try RunnerLaunchSpec.parse(
            ["run", "-NSDocumentRevisionsDebugMode", "YES", "--profile", id.uuidString]
        )
        XCTAssertEqual(parsed.profileID, id)
    }

    func testSPIOverrideRoundTripsAndDefaultsToProfile() throws {
        for override in [SPIFeatures.all, [], [.engineTimeZone]] {
            let spec = RunnerLaunchSpec(profileID: id, spiOverride: override)
            XCTAssertEqual(try RunnerLaunchSpec.parse(spec.arguments()), spec)
        }
        XCTAssertNil(try RunnerLaunchSpec.parse(RunnerLaunchSpec(profileID: id).arguments()).spiOverride)
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(["run", "--profile", id.uuidString, "--spi", "canvas"])) {
            XCTAssertEqual($0 as? RunnerLaunchSpecError, .invalidSPI("canvas"))
        }
    }

    func testParseErrors() {
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(["list"])) {
            XCTAssertEqual($0 as? RunnerLaunchSpecError, .missingSubcommand)
        }
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(["run"])) {
            XCTAssertEqual($0 as? RunnerLaunchSpecError, .missingProfileID)
        }
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(["run", "--profile", "nope"])) {
            XCTAssertEqual($0 as? RunnerLaunchSpecError, .invalidProfileID("nope"))
        }
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(["run", "--profile"])) {
            XCTAssertEqual($0 as? RunnerLaunchSpecError, .missingValue("--profile"))
        }
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(["run", "--profile", id.uuidString, "--url", "not a url"])) {
            XCTAssertEqual($0 as? RunnerLaunchSpecError, .invalidURL("not a url"))
        }
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(["run", "--profile", id.uuidString, "--bogus"])) {
            XCTAssertEqual($0 as? RunnerLaunchSpecError, .unknownArgument("--bogus"))
        }
    }
}
