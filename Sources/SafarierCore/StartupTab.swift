import Foundation

/// 一个可独立暂停的启动页签；顺序由 Profile.startupTabs 决定。
public struct StartupTab: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var isEnabled: Bool

    public init(id: UUID = UUID(), url: URL, isEnabled: Bool = true) {
        self.id = id
        self.url = url
        self.isEnabled = isEnabled
    }
}
