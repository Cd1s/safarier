import XCTest
@testable import SafarierCore

final class CountryLocaleTests: XCTestCase {
    func testTimeZonesSelectTheirCountryRatherThanOffsetOrContinent() {
        for zone in ["America/Los_Angeles", "America/New_York", "America/Chicago", "America/Denver", "Pacific/Honolulu"] {
            XCTAssertEqual(CountryLocaleTable.locale(forTimeZone: zone)?.languages, ["en-US", "en"], zone)
        }
        for (zone, language) in [
            ("America/Toronto", "en-CA"), ("America/Lima", "es-PE"), ("America/Guayaquil", "es-EC"),
            ("Asia/Shanghai", "zh-CN"), ("Asia/Hong_Kong", "zh-HK"), ("Asia/Taipei", "zh-TW"),
            ("Asia/Tokyo", "ja-JP"), ("Asia/Seoul", "ko-KR"), ("Asia/Bangkok", "th-TH"),
            ("Asia/Singapore", "en-SG"), ("Europe/London", "en-GB"), ("Europe/Berlin", "de-DE"),
        ] {
            XCTAssertEqual(CountryLocaleTable.locale(forTimeZone: zone)?.languages.first, language, zone)
        }
    }

    func testTimeZoneAliasesAndNonRegionalZones() {
        for (alias, canonical) in [("US/Pacific", "America/Los_Angeles"), ("Asia/Calcutta", "Asia/Kolkata"), ("Japan", "Asia/Tokyo")] {
            XCTAssertEqual(CountryLocaleTable.locale(forTimeZone: alias), CountryLocaleTable.locale(forTimeZone: canonical), alias)
        }
        for zone in ["UTC", "GMT", "Etc/GMT+5", "Mars/Phobos"] {
            XCTAssertNil(CountryLocaleTable.locale(forTimeZone: zone), zone)
        }
    }

    func testAutomaticLanguagesPreferEffectiveTimeZoneAndPreserveCustomLanguages() {
        var profile = Profile(name: "us", mode: .ephemeral, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(profile.resolvedLanguages(), ["en-US", "en"])
        profile.followProxyLanguages = true
        XCTAssertEqual(profile.resolvedLanguages(proxyLanguages: ["zh-CN"], proxyTimeZone: "Asia/Shanghai"), ["en-US", "en"])
        profile.followProxyTimeZone = true
        XCTAssertEqual(profile.resolvedLanguages(proxyLanguages: ["zh-CN"], proxyTimeZone: "America/Chicago"), ["en-US", "en"])
        XCTAssertEqual(profile.resolvedLanguages(), [], "未解析时不能沿用存储的旧时区")
        profile.followProxyLanguages = false
        XCTAssertEqual(profile.resolvedLanguages(proxyTimeZone: "Asia/Tokyo"), ["ja-JP", "ja"], "只跟随代理时区也应同步语言")
        profile.languages = ["fr-FR", "fr"]
        XCTAssertEqual(profile.resolvedLanguages(proxyTimeZone: "America/New_York"), ["fr-FR", "fr"])
    }

    func testAutomaticLanguagesFallBackToProxyThenSystem() {
        var profile = Profile(name: "auto", mode: .ephemeral)
        XCTAssertEqual(profile.resolvedLanguages(), [])
        profile.followProxyLanguages = true
        XCTAssertEqual(profile.resolvedLanguages(proxyLanguages: ["en-US", "en"]), ["en-US", "en"])
        profile.timeZoneIdentifier = "UTC"
        XCTAssertEqual(profile.resolvedLanguages(proxyLanguages: ["ja-JP", "ja"]), ["ja-JP", "ja"])
        XCTAssertEqual(profile.resolvedLanguages(), [])
    }
}
