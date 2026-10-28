import Foundation
import Darwin

/// 通用的本地 JSON 元数据存储：带版本号，原子写入，文件不存在时视为空列表。
/// 含自定义出站等敏感字段的记录使用私有文件写入。
public final class JSONDocumentStore<Record: Codable & Sendable>: @unchecked Sendable {
    public struct Document: Codable {
        public var version: Int
        public var records: [Record]
    }

    public static var currentVersion: Int { 1 }

    public let fileURL: URL
    private let privateFile: Bool

    public init(fileURL: URL, privateFile: Bool = false) {
        self.fileURL = fileURL
        self.privateFile = privateFile
    }

    public func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try Self.decode(data)
    }

    public func save(_ records: [Record]) throws {
        let data = try Self.encode(records)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if privateFile {
            // 先以 0600 创建临时文件再原子替换，避免首次保存时短暂暴露认证信息。
            let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public static func encode(_ records: [Record]) throws -> Data {
        let encoder = JSONEncoder()
        // 用默认的参考日秒数（Double）：能精确往返。ISO 8601 会丢掉秒以下精度，读回的记录就不再相等。
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(version: currentVersion, records: records))
    }

    public static func decode(_ data: Data) throws -> [Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let document = try decoder.decode(Document.self, from: data)
        guard document.version <= currentVersion else {
            throw StoreError.unsupportedVersion(document.version)
        }
        return document.records
    }

    public enum StoreError: Error, Equatable {
        case unsupportedVersion(Int)
    }
}

public extension FileManager {
    /// `~/Library/Application Support/Safarier/`；设置了 `SAFARIER_HOME` 时改用该目录（测试、冒烟用）。
    static func safarierSupportDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SAFARIER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Safarier", isDirectory: true)
    }
}
