import XCTest
@testable import SafarierCore

final class ProfileTests: XCTestCase {
    func testValidProfilePasses() throws {
        let profile = Profile(
            name: "Work",
            mode: .persistent,
            languages: ["en-US", "en"],
            timeZoneIdentifier: "America/Los_Angeles",
            startURL: URL(string: "https://example.com"),
            notes: "note"
        )
        XCTAssertNoThrow(try profile.validate())
    }

    func testEmptyNameThrows() {
        let profile = Profile(name: "   ", mode: .ephemeral)
        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .emptyName)
        }
    }

    func testNameTooLongThrows() {
        let name = String(repeating: "a", count: 65)
        let profile = Profile(name: name, mode: .ephemeral)
        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .nameTooLong(65))
        }
    }

    func testInvalidLanguageTagThrows() {
        let profile = Profile(name: "P", mode: .ephemeral, languages: ["en_US"])
        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .invalidLanguageTag("en_US"))
        }
    }

    func testUnknownTimeZoneThrows() {
        let profile = Profile(name: "P", mode: .ephemeral, timeZoneIdentifier: "Mars/Phobos")
        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .unknownTimeZone("Mars/Phobos"))
        }
    }

    func testUnsupportedStartURLSchemeThrows() {
        let profile = Profile(name: "P", mode: .ephemeral, startURL: URL(string: "ftp://example.com"))
        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .unsupportedStartURLScheme("ftp"))
        }
    }

    func testLegacyJSONDecodesWithDefaults() throws {
        let json = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Legacy",
            "mode": "persistent",
            "createdAt": 0
        }
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.name, "Legacy")
        XCTAssertEqual(profile.mode, .persistent)
        XCTAssertNil(profile.proxyID)
        XCTAssertEqual(profile.languages, [])
        XCTAssertNil(profile.timeZoneIdentifier)
        XCTAssertNil(profile.startURL)
        XCTAssertEqual(profile.notes, "")
        XCTAssertEqual(profile.spi, [], "旧记录没有 spi 字段时保持关闭，不因默认值变化而改变已有环境")
        XCTAssertFalse(profile.followProxyLanguages)
        XCTAssertFalse(profile.followProxyTimeZone)
    }

    func testFollowProxyFieldsRoundTrip() throws {
        let profile = Profile(name: "Follow", mode: .persistent, followProxyLanguages: true, followProxyTimeZone: true)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertTrue(decoded.followProxyLanguages)
        XCTAssertTrue(decoded.followProxyTimeZone)
        XCTAssertEqual(decoded, profile)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testDuplicateNameAddsIncrementingSuffix() {
        XCTAssertEqual(Profile.duplicateName(for: "美国-工作", existing: []), "美国-工作 副本")
        XCTAssertEqual(Profile.duplicateName(for: "美国-工作", existing: ["美国-工作", "美国-工作 副本"]), "美国-工作 副本 2")
        XCTAssertEqual(
            Profile.duplicateName(for: "美国-工作", existing: ["美国-工作 副本", "美国-工作 副本 2", "美国-工作 副本 3"]),
            "美国-工作 副本 4"
        )
        XCTAssertEqual(Profile.duplicateName(for: "  A  ", existing: []), "A 副本")
    }

    func testDuplicateNameStaysWithinMaxLength() throws {
        let long = String(repeating: "长", count: 64)
        let first = Profile.duplicateName(for: long, existing: [])
        XCTAssertEqual(first.count, Profile.maxNameLength)
        XCTAssertTrue(first.hasSuffix(" 副本"))
        let second = Profile.duplicateName(for: long, existing: [first])
        XCTAssertEqual(second.count, Profile.maxNameLength)
        XCTAssertTrue(second.hasSuffix(" 副本 2"))
        XCTAssertNoThrow(try Profile(name: second, mode: .persistent).validate())
    }

    func testDuplicatedCopiesSettingsWithNewID() {
        let original = Profile(
            name: "原环境", mode: .ephemeral, proxyID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            languages: ["th-TH", "th"], timeZoneIdentifier: "Asia/Bangkok",
            followProxyLanguages: true, followProxyTimeZone: false,
            startURL: URL(string: "https://example.com"), notes: "备注",
            spi: [.fingerprintingProtections, .disableWebRTC],
            subscriptionID: UUID(), nodeName: "🇹🇭 Bangkok 01", deviceModel: "macbook-air-13-m2"
        )
        let copy = original.duplicated(name: "原环境 副本")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "原环境 副本")
        XCTAssertGreaterThan(copy.createdAt, original.createdAt)
        XCTAssertEqual(copy.mode, original.mode)
        XCTAssertEqual(copy.proxyID, original.proxyID)
        XCTAssertEqual(copy.languages, original.languages)
        XCTAssertEqual(copy.timeZoneIdentifier, original.timeZoneIdentifier)
        XCTAssertEqual(copy.followProxyLanguages, original.followProxyLanguages)
        XCTAssertEqual(copy.followProxyTimeZone, original.followProxyTimeZone)
        XCTAssertEqual(copy.startURL, original.startURL)
        XCTAssertEqual(copy.notes, original.notes)
        XCTAssertEqual(copy.spi, original.spi)
        XCTAssertEqual(copy.subscriptionID, original.subscriptionID)
        XCTAssertEqual(copy.nodeName, original.nodeName)
        XCTAssertEqual(copy.deviceModel, original.deviceModel)
    }

    func testEncodeDecodeRoundTrip() throws {
        let profile = Profile(
            name: "RoundTrip",
            mode: .ephemeral,
            proxyID: UUID(),
            languages: ["ja-JP"],
            timeZoneIdentifier: "Asia/Tokyo",
            startURL: URL(string: "https://example.org/start"),
            notes: "hello"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }
}
