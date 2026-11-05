import Foundation

public enum ProxyChainError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case selfReference
    case missingProxy
    case missingSubscription
    case missingNode
    case multipleHops
    case usedAsUpstream
    case unresolvedChain

    public var description: String { errorDescription ?? L10n.text("链式代理配置无效。") }

    public var errorDescription: String? {
        switch self {
        case .selfReference: return L10n.text("前置代理不能选择当前代理。")
        case .missingProxy: return L10n.text("前置代理已被删除，请重新选择；连接已阻止。")
        case .missingSubscription: return L10n.text("前置订阅已被删除，请重新选择；连接已阻止。")
        case .missingNode: return L10n.text("前置节点已不在订阅中，请重新选择；连接已阻止。")
        case .multipleHops: return L10n.text("目前仅支持两跳，请选择未配置前置连接的代理。")
        case .usedAsUpstream: return L10n.text("此代理正被其他代理用作前置，不能再添加前置连接。")
        case .unresolvedChain: return L10n.text("链式代理需要先解析完整链路，已阻止直接连接出口。")
        }
    }
}

/// 校验通过的前置：已保存代理和订阅节点是本次读到的记录，自定义 JSON 由 SafarierNetwork 再解析。
public enum ProxyChainEntry: Equatable, Sendable {
    case proxy(ProxySettings)
    case node(SubscriptionNode)
    case custom(String)
}

public extension SafarierWorkspace {
    /// 保存和运行时都核验引用。前置缺失时抛错，不能退回单跳。
    @discardableResult
    func validateProxyChain(_ proxy: ProxySettings) throws -> ProxyChainEntry? {
        try validateProxyChain(proxy, among: proxies.all())
    }

    /// `records` 是同一次读取的全部代理；保存时在文件锁内传入，两个进程同时保存也凑不出三跳。
    func validateProxyChain(_ proxy: ProxySettings, among records: [ProxySettings]) throws -> ProxyChainEntry? {
        try proxy.validate()
        guard let upstream = proxy.upstream else { return nil }
        if records.contains(where: { $0.id != proxy.id && $0.upstream?.proxyID == proxy.id }) {
            throw ProxyChainError.usedAsUpstream
        }
        switch upstream {
        case .proxy(let id):
            guard id != proxy.id else { throw ProxyChainError.selfReference }
            guard let entry = records.first(where: { $0.id == id }) else { throw ProxyChainError.missingProxy }
            guard entry.upstream == nil else { throw ProxyChainError.multipleHops }
            try entry.validate()
            return .proxy(entry)
        case .node(let id, let name):
            guard let subscription = try subscriptions.record(id: id) else { throw ProxyChainError.missingSubscription }
            guard let node = subscription.nodes.first(where: { $0.name == name }) else { throw ProxyChainError.missingNode }
            try node.validate()
            return .node(node)
        case .custom(let json):
            return .custom(json) // JSON 和协议由 SafarierNetwork 校验。
        }
    }

    /// 在代理文件锁内校验链路并写入。
    func insertProxy(_ proxy: ProxySettings) throws {
        try proxies.insert(proxy) { _ = try validateProxyChain(proxy, among: $0) }
    }

    func updateProxy(_ proxy: ProxySettings) throws {
        try proxies.update(proxy) { _ = try validateProxyChain(proxy, among: $0) }
    }

    func proxies(usingProxyID id: UUID) throws -> [ProxySettings] {
        try proxies.all().filter { $0.upstream?.proxyID == id }
    }

    func proxies(usingSubscriptionID id: UUID) throws -> [ProxySettings] {
        try proxies.all().filter { $0.upstream?.subscriptionID == id }
    }
}
