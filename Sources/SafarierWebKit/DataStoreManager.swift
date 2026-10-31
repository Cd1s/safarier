import WebKit
import SafarierCore

/// 按 Profile 分配 WKWebsiteDataStore：persistent 绑定固定标识，ephemeral 每次新建。
@MainActor
public final class DataStoreManager {
    /// 照 Safari 建数据存储要用的原生引擎接口（全部按名字动态查找，见 `safariDataStore(for:)`）。
    public struct Symbols: Sendable {
        public var configurationClass = SFRSymbolDecoder.decode([0x05, 0x0D, 0x11, 0x0D, 0x3F, 0x38, 0x29, 0x33, 0x2E, 0x3F, 0x1E, 0x3B, 0x2E, 0x3B, 0x09, 0x2E, 0x35, 0x28, 0x3F, 0x19, 0x35, 0x34, 0x3C, 0x33, 0x3D, 0x2F, 0x28, 0x3B, 0x2E, 0x33, 0x35, 0x34])
        public var nonPersistentInitializer = SFRSymbolDecoder.decode([0x33, 0x34, 0x33, 0x2E, 0x14, 0x35, 0x34, 0x0A, 0x3F, 0x28, 0x29, 0x33, 0x29, 0x2E, 0x3F, 0x34, 0x2E, 0x19, 0x35, 0x34, 0x3C, 0x33, 0x3D, 0x2F, 0x28, 0x3B, 0x2E, 0x33, 0x35, 0x34])
        public var storeInitializer = SFRSymbolDecoder.decode([0x05, 0x33, 0x34, 0x33, 0x2E, 0x0D, 0x33, 0x2E, 0x32, 0x19, 0x35, 0x34, 0x3C, 0x33, 0x3D, 0x2F, 0x28, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x60])
        /// 配置上要和 Safari 一样打开的两项（裸配置默认都是 NO，2026-10-31 本机实测）：快速证书校验、缓存推测校验。
        public var configurationSwitches: [(getter: String, setter: String, label: String)] = [
            (SFRSymbolDecoder.decode([0x3C, 0x3B, 0x29, 0x2E, 0x09, 0x3F, 0x28, 0x2C, 0x3F, 0x28, 0x0E, 0x28, 0x2F, 0x29, 0x2E, 0x1F, 0x2C, 0x3B, 0x36, 0x2F, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]),
             SFRSymbolDecoder.decode([0x29, 0x3F, 0x2E, 0x1C, 0x3B, 0x29, 0x2E, 0x09, 0x3F, 0x28, 0x2C, 0x3F, 0x28, 0x0E, 0x28, 0x2F, 0x29, 0x2E, 0x1F, 0x2C, 0x3B, 0x36, 0x2F, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60]),
             "快速证书校验"),
            (SFRSymbolDecoder.decode([0x34, 0x3F, 0x2E, 0x2D, 0x35, 0x28, 0x31, 0x19, 0x3B, 0x39, 0x32, 0x3F, 0x09, 0x2A, 0x3F, 0x39, 0x2F, 0x36, 0x3B, 0x2E, 0x33, 0x2C, 0x3F, 0x0C, 0x3B, 0x36, 0x33, 0x3E, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E]),
             SFRSymbolDecoder.decode([0x29, 0x3F, 0x2E, 0x14, 0x3F, 0x2E, 0x2D, 0x35, 0x28, 0x31, 0x19, 0x3B, 0x39, 0x32, 0x3F, 0x09, 0x2A, 0x3F, 0x39, 0x2F, 0x36, 0x3B, 0x2E, 0x33, 0x2C, 0x3F, 0x0C, 0x3B, 0x36, 0x33, 0x3E, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60]),
             "缓存推测校验"),
        ]
        /// 智能防跟踪（ITP）。本机 WebKit 新建的数据存储默认已经开着，照 Safari 再确认一遍。
        public var statisticsGetter = SFRSymbolDecoder.decode([0x05, 0x28, 0x3F, 0x29, 0x35, 0x2F, 0x28, 0x39, 0x3F, 0x16, 0x35, 0x3B, 0x3E, 0x09, 0x2E, 0x3B, 0x2E, 0x33, 0x29, 0x2E, 0x33, 0x39, 0x29, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E])
        public var statisticsSetter = SFRSymbolDecoder.decode([0x05, 0x29, 0x3F, 0x2E, 0x08, 0x3F, 0x29, 0x35, 0x2F, 0x28, 0x39, 0x3F, 0x16, 0x35, 0x3B, 0x3E, 0x09, 0x2E, 0x3B, 0x2E, 0x33, 0x29, 0x2E, 0x33, 0x39, 0x29, 0x1F, 0x34, 0x3B, 0x38, 0x36, 0x3F, 0x3E, 0x60])

        public init() {}

        public static let webKit = Symbols()
    }

    public let symbols: Symbols

    public init(symbols: Symbols = .webKit) {
        self.symbols = symbols
    }

    /// 只用公开 API：
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

    /// 照 Safari 建数据存储（profile 开着 safari 时由配置工厂调用），返回数据存储和能力报告 dataIsolation 的结论：
    /// - 临时环境照 Safari 无痕的做法：建内存数据存储配置、打开快速证书校验和缓存推测校验并回读，再用它建数据存储。
    ///   任何一步不可用或失败、回读不一致，或者建出来的不是内存存储，都退回 `WKWebsiteDataStore.nonPersistent()`；
    /// - 不论持久还是临时，都确认智能防跟踪（ITP）开着。
    public func safariDataStore(for profile: Profile) -> (store: WKWebsiteDataStore, state: CapabilityState) {
        var notes: [String] = []
        var degraded = false
        let store: WKWebsiteDataStore
        switch profile.mode {
        case .persistent:
            store = WKWebsiteDataStore(forIdentifier: profile.id)
            notes.append("WKWebsiteDataStore(forIdentifier: \(profile.id.uuidString))")
        case .ephemeral:
            switch nativeNonPersistentDataStore() {
            case .success(let native):
                store = native
                notes.append("Safari 无痕同款内存数据存储（\(symbols.configurationSwitches.map(\.label).joined(separator: "、"))已打开，回读一致），窗口关闭即销毁")
            case .failure(let failure):
                store = WKWebsiteDataStore.nonPersistent()
                degraded = !failure.isUnsupported
                notes.append("WKWebsiteDataStore.nonPersistent()，窗口关闭即销毁；Safari 无痕数据存储配置\(failure.isUnsupported ? "不可用" : "没有生效")，已退回公开 API（\(failure)）")
            }
        }
        switch enableResourceLoadStatistics(on: store) {
        case .success:
            notes.append("智能防跟踪（ITP）开启（回读一致）")
        case .failure(let failure) where failure.isUnsupported:
            notes.append("本机引擎没有智能防跟踪开关，保持默认（\(failure)）")
        case .failure(let failure):
            degraded = true
            notes.append("智能防跟踪没有确认开启（\(failure)）")
        }
        let text = notes.joined(separator: "；")
        return (store, degraded ? .degraded(text) : .active(text))
    }

    /// Safari 无痕的建法。只有建出来的确实是内存存储（公开的 isPersistent 为 NO）才返回成功。
    func nativeNonPersistentDataStore() -> Result<WKWebsiteDataStore, SPICallFailure> {
        let configuration: NSObject
        switch SPIRuntimeBridge.allocInit(className: symbols.configurationClass, initializer: symbols.nonPersistentInitializer) {
        case .success(let value): configuration = value
        case .failure(let failure): return .failure(failure)
        }
        for item in symbols.configurationSwitches {
            if case .failure(let failure) = SPIRuntimeBridge.setBool(true, item.setter, on: configuration) { return .failure(failure) }
            switch SPIRuntimeBridge.getBool(item.getter, on: configuration) {
            case .success(true): continue
            case .success(false): return .failure(.exception("\(item.label)写入 YES 后回读仍为 NO"))
            case .failure(let failure): return .failure(failure)
            }
        }
        switch SPIRuntimeBridge.allocInit(className: NSStringFromClass(WKWebsiteDataStore.self), initializer: symbols.storeInitializer, argument: configuration) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let object):
            guard let store = object as? WKWebsiteDataStore else { return .failure(.signatureMismatch("建出来的不是数据存储对象")) }
            // 临时环境绝不能落盘：建出来的若是持久存储就不用。
            guard !store.isPersistent else { return .failure(.exception("建出来的不是内存存储")) }
            return .success(store)
        }
    }

    /// 打开智能防跟踪并回读。
    func enableResourceLoadStatistics(on store: WKWebsiteDataStore) -> Result<Void, SPICallFailure> {
        if case .failure(let failure) = SPIRuntimeBridge.setBool(true, symbols.statisticsSetter, on: store) { return .failure(failure) }
        switch SPIRuntimeBridge.getBool(symbols.statisticsGetter, on: store) {
        case .success(true): return .success(())
        case .success(false): return .failure(.exception("写入 YES 后回读仍为 NO"))
        case .failure(let failure): return .failure(failure)
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
