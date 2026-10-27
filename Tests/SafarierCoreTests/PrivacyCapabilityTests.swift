import XCTest
@testable import SafarierCore

final class PrivacyCapabilityTests: XCTestCase {
    func testUnsetFeatureIsReportedAsUnevaluated() {
        let report = PrivacyCapabilityReport()
        XCTAssertEqual(report[.webRTCDisabled], .unavailable("未评估"))
    }

    func testLinesFollowFeatureOrderAndJSONRoundTrips() throws {
        var report = PrivacyCapabilityReport()
        report.set(.active("WKWebsiteDataStore(forIdentifier:)"), for: .dataIsolation)
        report.set(.notRequested, for: .proxy)

        let lines = report.lines()
        XCTAssertEqual(lines.count, PrivacyFeature.allCases.count)
        XCTAssertEqual(lines[1], "dataIsolation: active — WKWebsiteDataStore(forIdentifier:)")
        XCTAssertEqual(lines[2], "proxy: notRequested")

        let data = try JSONEncoder().encode(report)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"dataIsolation\""))
        XCTAssertEqual(try JSONDecoder().decode(PrivacyCapabilityReport.self, from: data), report)
    }
}
