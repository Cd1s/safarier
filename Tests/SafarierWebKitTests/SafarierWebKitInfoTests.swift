import XCTest
@testable import SafarierWebKit

final class SafarierWebKitInfoTests: XCTestCase {
    func testSystemWebKitVersionIsReadable() {
        XCTAssertNotNil(SafarierWebKitInfo.systemWebKitVersion)
    }
}
