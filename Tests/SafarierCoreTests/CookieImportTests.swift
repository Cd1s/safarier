import XCTest
@testable import SafarierCore

final class CookieImportTests: XCTestCase {
    func testParsesJSONArrayAndObject() throws {
        let json = """
        [
          {
            "name": "session_id",
            "value": "abc123",
            "domain": ".example.com",
            "path": "/",
            "secure": true,
            "httpOnly": true,
            "expirationDate": 1893456000,
            "sameSite": "lax"
          },
          {
            "name": "",
            "value": "ignored",
            "domain": "example.com"
          }
        ]
        """
        let result = try CookieImportParser.parse(json)
        XCTAssertEqual(result.format, .json)
        XCTAssertEqual(result.cookies.count, 1)
        XCTAssertEqual(result.skippedCount, 1)

        let cookie = try XCTUnwrap(result.cookies.first)
        XCTAssertEqual(cookie.name, "session_id")
        XCTAssertEqual(cookie.value, "abc123")
        XCTAssertEqual(cookie.domain, ".example.com")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.sameSitePolicy, .sameSiteLax)

        let wrapped = #"{"cookies":[{"name":"a","value":"1","domain":"example.org","expires":1893456000000}]}"#
        let wrappedResult = try CookieImportParser.parse(wrapped)
        XCTAssertEqual(wrappedResult.cookies.count, 1)
        XCTAssertNotNil(wrappedResult.cookies.first?.expiresDate)
    }

    func testParsesNetscapeFormat() throws {
        let netscape = """
        # Netscape HTTP Cookie File
        .example.com\tTRUE\t/\tTRUE\t1893456000\tsid\tval=1\t2
        #HttpOnly_app.example.com\tFALSE\t/app\tFALSE\t0\ttoken\txyz
        malformed_line
        """
        let result = try CookieImportParser.parse(netscape)
        XCTAssertEqual(result.format, .netscape)
        XCTAssertEqual(result.cookies.count, 2)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.cookies[0].value, "val=1\t2")
        XCTAssertTrue(result.cookies[0].isSecure)
        XCTAssertTrue(result.cookies[1].isHTTPOnly)
        XCTAssertNil(result.cookies[1].expiresDate)
    }

    func testErrorsOnEmptyOrInvalidInput() {
        XCTAssertThrowsError(try CookieImportParser.parse("   ")) { error in
            XCTAssertEqual(error as? CookieImportError, .emptyInput)
        }
        XCTAssertThrowsError(try CookieImportParser.parse("[invalid"))
        XCTAssertThrowsError(try CookieImportParser.parse("# only comments")) { error in
            XCTAssertEqual(error as? CookieImportError, .noValidCookies)
        }
    }
}
