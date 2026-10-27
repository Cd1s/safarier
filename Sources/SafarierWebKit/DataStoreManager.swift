import WebKit
import SafarierCore

/// 按 Profile 分配 WKWebsiteDataStore：persistent 绑定固定标识，ephemeral 每次新建。
@MainActor
public final class DataStoreManager {
    public init() {}

    /// persistent → WKWebsiteDataStore(forIdentifier: profile.id)
    /// ephemeral  → WKWebsiteDataStore.nonPersistent()（每次调用新建一个）
    public func dataStore(for profile: Profile) -> WKWebsiteDataStore {
        switch profile.mode {
        case .persistent:
            return WKWebsiteDataStore(forIdentifier: profile.id)
        case .ephemeral:
            return WKWebsiteDataStore.nonPersistent()
        }
    }

    /// 删除该 profile 的持久数据。
    public func removePersistentData(for profileID: UUID) async throws {
        Self.ensureWebKitInitialized()
        try await WKWebsiteDataStore.remove(forIdentifier: profileID)
    }

    /// 进程里还没创建过任何 WebKit API 对象时（例如命令行 Manager），直接调 `remove(forIdentifier:)`
    /// 会在 WebsiteDataStoreIO 队列里访问未初始化的主 RunLoop 而崩溃（2026-10-24 在 macOS 15.7.3 实测）。
    /// 先创建一个配置对象，让 WebKit 完成主线程初始化。
    private static var webKitInitialized = false
    private static func ensureWebKitInitialized() {
        guard !webKitInitialized else { return }
        _ = WKWebViewConfiguration()
        webKitInitialized = true
    }

    /// 系统里已有的持久 data store 标识。
    public func persistentIdentifiers() async -> [UUID] {
        await WKWebsiteDataStore.allDataStoreIdentifiers
    }
}
