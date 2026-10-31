import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SafarierCore

final class UpdateCheckerTests: XCTestCase {
    func testVersionParsingAcceptsPrefixAndPadding() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("V2.0"), SemanticVersion(major: 2))
        XCTAssertEqual(SemanticVersion(" 3 "), SemanticVersion(major: 3))
        XCTAssertEqual(SemanticVersion("1.2.3-beta.1+7"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("v1.2.3").map(String.init(describing:)), "1.2.3")
    }

    func testVersionParsingRejectsGarbage() {
        for text in ["", "v", "abc", "1.x.3", "1..3", "1.2.3.4", "-1.2.3", "１.２.３"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    func testVersionComparisonIsNumeric() throws {
        let v = { (text: String) throws -> SemanticVersion in try XCTUnwrap(SemanticVersion(text)) }
        XCTAssertTrue(try v("1.2.3") > v("1.2.2"))
        XCTAssertTrue(try v("1.10.0") > v("1.2.9"))
        XCTAssertTrue(try v("2.0.0") > v("1.99.99"))
        XCTAssertTrue(try v("v1.2.2") == v("1.2.2"))
        XCTAssertTrue(try v("1.2.2") < v("v1.2.3"))
    }

    func testParseReleaseReadsGitHubFields() throws {
        let json = """
        {"tag_name":"v1.3.0","name":"Safarier 1.3.0","body":"- 新增检查更新","html_url":"https://github.com/Cd1s/safarier/releases/tag/v1.3.0","draft":false}
        """
        let release = try UpdateChecker.parseRelease(from: Data(json.utf8))
        XCTAssertEqual(release.tagName, "v1.3.0")
        XCTAssertEqual(release.name, "Safarier 1.3.0")
        XCTAssertEqual(release.body, "- 新增检查更新")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/Cd1s/safarier/releases/tag/v1.3.0")
    }

    func testParseReleaseFallsBackWhenOptionalFieldsAreMissing() throws {
        let release = try UpdateChecker.parseRelease(from: Data(#"{"tag_name":"v1.3.0"}"#.utf8))
        XCTAssertEqual(release.name, "v1.3.0")
        XCTAssertEqual(release.body, "")
        XCTAssertEqual(release.htmlURL, UpdateChecker.releasesURL)
    }

    func testParseReleaseIgnoresLinksOutsideTheRepository() throws {
        for link in ["https://evil.example/releases", "http://github.com/Cd1s/safarier/releases/tag/v9", "https://github.com/other/repo/releases/tag/v9", "file:///etc/passwd"] {
            let json = #"{"tag_name":"v9.0.0","html_url":"\#(link)"}"#
            XCTAssertEqual(try UpdateChecker.parseRelease(from: Data(json.utf8)).htmlURL, UpdateChecker.releasesURL, link)
        }
    }

    func testParseReleaseRejectsInvalidPayloads() {
        for json in ["", "[]", "{}", #"{"tag_name":""}"#, #"{"message":"Not Found"}"#] {
            XCTAssertThrowsError(try UpdateChecker.parseRelease(from: Data(json.utf8)), json) {
                XCTAssertEqual($0 as? UpdateCheckError, .invalidResponse)
            }
        }
    }

    func testCompareReportsUpdateUpToDateAndNewerLocalBuild() throws {
        let release = ReleaseInfo(tagName: "v1.2.3", name: "1.2.3", body: "", htmlURL: UpdateChecker.releasesURL)
        XCTAssertEqual(try UpdateChecker.compare(currentVersion: "1.2.2", latest: release), .updateAvailable(current: "1.2.2", latest: release))
        XCTAssertEqual(try UpdateChecker.compare(currentVersion: "1.2.3", latest: release), .upToDate(current: "1.2.3", latest: release))
        XCTAssertEqual(try UpdateChecker.compare(currentVersion: "1.3.0", latest: release), .upToDate(current: "1.3.0", latest: release))
        XCTAssertThrowsError(try UpdateChecker.compare(currentVersion: "dev", latest: release)) {
            XCTAssertEqual($0 as? UpdateCheckError, .invalidVersion("dev"))
        }
    }

    func testCheckLatestUsesInjectedLoaderAndChecksStatus() async throws {
        let body = Data(#"{"tag_name":"v1.10.0","html_url":"https://github.com/Cd1s/safarier/releases/tag/v1.10.0"}"#.utf8)
        func response(_ code: Int, _ request: URLRequest) -> URLResponse {
            HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        }

        let status = try await UpdateChecker.checkLatest(currentVersion: "1.2.9") { request in
            XCTAssertEqual(request.url, UpdateChecker.latestReleaseAPIURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Safarier/1.2.9")
            return (body, response(200, request))
        }
        guard case .updateAvailable(let current, let latest) = status else { return XCTFail("应提示有新版本：\(status)") }
        XCTAssertEqual(current, "1.2.9")
        XCTAssertEqual(latest.tagName, "v1.10.0")

        do {
            _ = try await UpdateChecker.checkLatest(currentVersion: "1.2.9") { request in (Data(), response(403, request)) }
            XCTFail("非 200 应该报错")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .httpStatus(403))
        }
    }

    func testLinksPointAtTheRepository() {
        XCTAssertEqual(UpdateChecker.repositoryURL.absoluteString, "https://github.com/Cd1s/safarier")
        XCTAssertEqual(UpdateChecker.releasesURL.absoluteString, "https://github.com/Cd1s/safarier/releases/latest")
        XCTAssertEqual(UpdateChecker.issuesURL.absoluteString, "https://github.com/Cd1s/safarier/issues")
        XCTAssertEqual(UpdateChecker.latestReleaseAPIURL.absoluteString, "https://api.github.com/repos/Cd1s/safarier/releases/latest")
    }
}
