import Foundation

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
        try locked {
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
        try locked {
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
        try locked {
            var records = try store.load()
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw RepositoryError.notFound(id)
            }
            let removed = records.remove(at: index)
            try store.save(records)
            return removed
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
