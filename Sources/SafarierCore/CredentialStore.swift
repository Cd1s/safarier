import Foundation
import Security

/// 凭据（代理密码等）存储抽象。绝不把密码写进元数据文件。
public protocol CredentialStore: Sendable {
    func password(forKey key: String) throws -> String?
    func setPassword(_ password: String, forKey key: String) throws
    /// key 不存在时不报错。
    func removePassword(forKey key: String) throws
}

/// 仅用于测试：内存字典，不接触系统 Keychain。
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func password(forKey key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func setPassword(_ password: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = password
    }

    public func removePassword(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = nil
    }
}

/// 基于 macOS Keychain 的 generic password 实现。
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "app.safarier.proxy") {
        self.service = service
    }

    public func password(forKey key: String) throws -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychain(errSecDecode)
        }
        return password
    }

    public func setPassword(_ password: String, forKey key: String) throws {
        let query = baseQuery(forKey: key)
        let data = Data(password.utf8)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychain(addStatus)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(updateStatus)
        }
    }

    public func removePassword(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

public enum CredentialStoreError: Error, Equatable {
    case keychain(OSStatus)
}
