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
        try mutate { records in
            guard !records.contains(where: { $0.id == record.id }) else {
                throw RepositoryError.duplicateID(record.id)
            }
            records.append(record)
        }
    }

    public func update(_ record: Record) throws {
        try record.validate()
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.id == record.id }) else {
                throw RepositoryError.notFound(record.id)
            }
            records[index] = record
        }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Record {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw RepositoryError.notFound(id)
            }
            return records.remove(at: index)
        }
    }

    /// 在同一把文件锁内完成读取、修改和保存；修改失败不写回。
    /// JSON 原子替换会改变 inode，因此锁独立文件，且不在解锁后删除它。
    private func mutate<T>(_ body: (inout [Record]) throws -> T) throws -> T {
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
            var records = try store.load()
            let result = try body(&records)
            try store.save(records)
            return result
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
            fileURL: directory.appendingPathComponent("profiles.json"), privateFile: true
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
