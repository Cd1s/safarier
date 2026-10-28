import Foundation
import Darwin

/// 可落盘、可校验的记录。
public protocol ValidatableRecord: Codable, Identifiable, Sendable where ID == UUID {
    func validate() throws
}

extension Profile: ValidatableRecord {}
extension ProxySettings: ValidatableRecord {}

public enum RepositoryError: Error, Equatable {
    case duplicateID(UUID)
    case notFound(UUID)
}

/// 基于 `JSONDocumentStore` 的通用 CRUD。每次操作都 load → 改 → save，不做缓存。
public final class RecordRepository<Record: ValidatableRecord>: @unchecked Sendable {
    private let store: JSONDocumentStore<Record>
    private let lock = NSLock()

    public init(store: JSONDocumentStore<Record>) {
        self.store = store
    }

    /// 保持文件里的顺序。
    public func all() throws -> [Record] {
        try locked { try store.load() }
    }

    public func record(id: UUID) throws -> Record? {
        try locked { try store.load().first { $0.id == id } }
    }

    public func insert(_ record: Record) throws {
        try record.validate()
        try withWriteLock {
            var records = try store.load()
            guard !records.contains(where: { $0.id == record.id }) else {
                throw RepositoryError.duplicateID(record.id)
            }
            records.append(record)
            try store.save(records)
        }
    }

    public func update(_ record: Record) throws {
        try record.validate()
        try withWriteLock {
            var records = try store.load()
            guard let index = records.firstIndex(where: { $0.id == record.id }) else {
                throw RepositoryError.notFound(record.id)
            }
            records[index] = record
            try store.save(records)
        }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Record {
        try withWriteLock {
            var records = try store.load()
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw RepositoryError.notFound(id)
            }
            let removed = records.remove(at: index)
            try store.save(records)
            return removed
        }
    }

    /// 锁独立文件：JSON 原子替换会改变 inode，不能锁 JSON 本身，也不能在解锁后删除锁文件。
    private func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        try locked {
            let url = store.fileURL.appendingPathExtension("lock")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }
            defer { close(fd) }
            while flock(fd, LOCK_EX) != 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            defer { flock(fd, LOCK_UN) }
            return try body()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public typealias ProfileRepository = RecordRepository<Profile>
public typealias ProxyRepository = RecordRepository<ProxySettings>

public extension RecordRepository where Record == Profile {
    /// 文件位于 `directory/profiles.json`。
    static func profiles(in directory: URL) -> ProfileRepository {
        RecordRepository(store: JSONDocumentStore<Profile>(
            fileURL: directory.appendingPathComponent("profiles.json")
        ))
    }
}

public extension RecordRepository where Record == ProxySettings {
    /// 文件位于 `directory/proxies.json`。
    static func proxies(in directory: URL) -> ProxyRepository {
        RecordRepository(store: JSONDocumentStore<ProxySettings>(
            fileURL: directory.appendingPathComponent("proxies.json")
        ))
    }
}
