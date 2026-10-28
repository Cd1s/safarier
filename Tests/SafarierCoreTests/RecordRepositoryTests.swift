import XCTest
@testable import SafarierCore

final class RecordRepositoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testInsertAllRecordUpdateDelete() throws {
        let repository = ProfileRepository.profiles(in: directory)
        let first = Profile(name: "First", mode: .persistent)
        let second = Profile(name: "Second", mode: .ephemeral)

        try repository.insert(first)
        try repository.insert(second)

        XCTAssertEqual(try repository.all().map(\.id), [first.id, second.id])
        XCTAssertEqual(try repository.record(id: first.id), first)
        XCTAssertNil(try repository.record(id: UUID()))

        var renamed = first
        renamed.name = "Renamed"
        try repository.update(renamed)
        XCTAssertEqual(try repository.record(id: first.id)?.name, "Renamed")

        let removed = try repository.delete(id: first.id)
        XCTAssertEqual(removed, renamed)
        XCTAssertEqual(try repository.all(), [second])
    }

    func testDuplicateInsertThrows() throws {
        let repository = ProfileRepository.profiles(in: directory)
        let profile = Profile(name: "Dup", mode: .persistent)
        try repository.insert(profile)

        XCTAssertThrowsError(try repository.insert(profile)) { error in
            XCTAssertEqual(error as? RepositoryError, .duplicateID(profile.id))
        }
    }

    func testUpdateMissingThrowsNotFound() throws {
        let repository = ProfileRepository.profiles(in: directory)
        let profile = Profile(name: "Ghost", mode: .persistent)

        XCTAssertThrowsError(try repository.update(profile)) { error in
            XCTAssertEqual(error as? RepositoryError, .notFound(profile.id))
        }
    }

    func testDeleteMissingThrowsNotFound() throws {
        let repository = ProfileRepository.profiles(in: directory)
        let id = UUID()

        XCTAssertThrowsError(try repository.delete(id: id)) { error in
            XCTAssertEqual(error as? RepositoryError, .notFound(id))
        }
    }

    func testInvalidRecordInsertThrowsAndLeavesFileUnchanged() throws {
        let repository = ProfileRepository.profiles(in: directory)
        try repository.insert(Profile(name: "Valid", mode: .persistent))
        let fileURL = directory.appendingPathComponent("profiles.json")
        let before = try Data(contentsOf: fileURL)

        let invalid = Profile(name: "", mode: .persistent)
        XCTAssertThrowsError(try repository.insert(invalid)) { error in
            XCTAssertEqual(error as? ProfileValidationError, .emptyName)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testNewInstanceReadsPersistedData() throws {
        let profile = Profile(name: "Persisted", mode: .persistent, languages: ["en-US"])
        try ProfileRepository.profiles(in: directory).insert(profile)

        let reloaded = ProfileRepository.profiles(in: directory)
        XCTAssertEqual(try reloaded.all(), [profile])
    }

    func testProxyRepositoryUsesProxiesFile() throws {
        let repository = ProxyRepository.proxies(in: directory)
        let proxy = ProxySettings(name: "Proxy", kind: .httpConnect, host: "10.0.0.1", port: 3128)
        try repository.insert(proxy)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("proxies.json").path))
        XCTAssertEqual(try ProxyRepository.proxies(in: directory).all(), [proxy])
    }

    func testConcurrentRepositoriesPreserveEveryMutation() throws {
        let root = try XCTUnwrap(directory)
        let profiles = (0..<80).map { Profile(name: "Profile \($0)", mode: .ephemeral) }
        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            do { try ProfileRepository.profiles(in: root).insert(profiles[index]) }
            catch { XCTFail("并发插入失败：\(error)") }
        }
        XCTAssertEqual(Set(try ProfileRepository.profiles(in: root).all().map(\.id)), Set(profiles.map(\.id)))

        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            var profile = profiles[index]
            profile.name = "Updated \(index)"
            do { try ProfileRepository.profiles(in: root).update(profile) }
            catch { XCTFail("并发更新失败：\(error)") }
        }
        XCTAssertEqual(Set(try ProfileRepository.profiles(in: root).all().map(\.name)), Set((0..<80).map { "Updated \($0)" }))

        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            do { try ProfileRepository.profiles(in: root).delete(id: profiles[index].id) }
            catch { XCTFail("并发删除失败：\(error)") }
        }
        XCTAssertTrue(try ProfileRepository.profiles(in: root).all().isEmpty)
    }

    func testFailedMutationReleasesFileLock() throws {
        XCTAssertThrowsError(try ProfileRepository.profiles(in: directory).delete(id: UUID()))
        let profile = Profile(name: "After failure", mode: .ephemeral)
        try ProfileRepository.profiles(in: directory).insert(profile)
        XCTAssertEqual(try ProfileRepository.profiles(in: directory).all(), [profile])
    }
}
