import Foundation

/// 跨进程同步环境配置变更的本机通知标识（例如浏览器通过 ⌘D 写入或撤销启动页签后通知管理器实时刷新）。
/// 通知 `object` 绑定规范化的工作目录路径，确保 `SAFARIER_HOME` 隔离环境与自动化测试互不干扰。
public enum ProfilesSyncNotification: Sendable {
    public static let notificationName = Notification.Name("sh.safarier.profiles.changed")

    public static func workspaceScope(for root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func post(scope: String) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: scope,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
