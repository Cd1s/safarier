import Foundation
import SafarierCore

public enum InlineSubscriptionError: Error, Equatable {
    /// 解析出来一个节点都没有（空文本或全是注释）。
    case noNodes
    /// 既不是订阅网址，也不是节点链接或 Base64 订阅内容。
    case unrecognized
}

/// 直接粘贴的节点链接（`ss://`、`ss2022://`、`vless://`… 可多行，也可以是整段 Base64）当作一份订阅：
/// 原文存成元数据目录里的 `subscriptions-inline/<订阅 id>.txt`，订阅地址用这个文件的 `file://` URL。
/// 这样 `Subscription.validate()`（file 合法）和「刷新订阅」（重新读这个文件）都照常工作。
public enum InlineSubscription {
    public static let directoryName = "subscriptions-inline"

    public static func directory(in root: URL) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func fileURL(for id: UUID, in root: URL) -> URL {
        directory(in: root).appendingPathComponent("\(id.uuidString).txt")
    }

    /// 单行的 http / https / file 网址按订阅网址处理（返回它）；其它输入（节点链接、Base64、多行文本）返回 nil。
    public static func subscriptionURL(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isNewline),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return nil }
        return url
    }

    /// 先解析（至少一个支持的节点），通过后把原文写进 `subscriptions-inline/<id>.txt`（目录 0700、文件 0600：链接里有节点密码）。
    public static func store(_ input: String, id: UUID, in root: URL) throws -> (url: URL, result: SubscriptionParseResult) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: SubscriptionParseResult
        do {
            result = try SubscriptionParser.parseResult(text)
        } catch {
            // 解析失败又没有 `://`（Base64 解开后也没有节点链接）：多半是网址没写 https://，或者粘错了东西。
            if !text.contains("://") { throw InlineSubscriptionError.unrecognized }
            throw error
        }
        guard !result.nodes.isEmpty else { throw InlineSubscriptionError.noNodes }

        let manager = FileManager.default
        let directory = directory(in: root)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = fileURL(for: id, in: root)
        guard manager.createFile(atPath: url.path, contents: Data((text + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return (url, result)
    }

    /// 订阅地址是不是本机保存的粘贴链接（只认 `subscriptions-inline/` 下的文件）。
    public static func isInline(_ url: URL, in root: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.deletingLastPathComponent().path == directory(in: root).standardizedFileURL.path
    }

    /// 删除订阅时一起删掉保存的原文；不是粘贴链接的文件不碰。
    public static func remove(_ url: URL, in root: URL) {
        guard isInline(url, in: root) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
