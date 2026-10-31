import AppKit
import SafarierCore

/// 「关于 Safarier」「检查更新…」和 GitHub 页面入口，管理器和浏览器窗口共用。
@MainActor
enum AboutAndUpdateController {
    /// 调用方所在的进程。浏览器进程里的直连请求不走环境的代理（会泄露真实 IP），所以那边的「检查更新」只打开 Releases 页面，不发请求。
    enum Context {
        case manager
        case browser
    }

    static let fallbackVersion = "1.2.2"
    static let notesLimit = 600

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion
    }

    static var buildNumber: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    static var versionLine: String {
        "Safarier v\(currentVersion)" + (buildNumber.map { " (Build \($0))" } ?? "")
    }

    static func openGitHub() { NSWorkspace.shared.open(UpdateChecker.repositoryURL) }
    static func openReleases() { NSWorkspace.shared.open(UpdateChecker.releasesURL) }
    static func openIssues() { NSWorkspace.shared.open(UpdateChecker.issuesURL) }

    static func showAbout(context: Context = .manager) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = versionLine
        alert.informativeText = "基于 macOS 原生 WebKit 构建的多环境隔离浏览器\n\n\(UpdateChecker.repositoryURL.absoluteString)"
        alert.addButton(withTitle: "访问 GitHub 主页")
        alert.addButton(withTitle: "检查更新…")
        alert.addButton(withTitle: "好")
        switch alert.runModal() {
        case .alertFirstButtonReturn: openGitHub()
        case .alertSecondButtonReturn: checkForUpdates(context: context)
        default: break
        }
    }

    static func checkForUpdates(context: Context = .manager) {
        guard context == .manager else { return openReleases() }
        let current = currentVersion
        Task { @MainActor in
            do {
                present(try await UpdateChecker.checkLatest(currentVersion: current))
            } catch {
                presentFailure(error)
            }
        }
    }

    private static func present(_ status: UpdateStatus) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        switch status {
        case .updateAvailable(_, let latest):
            alert.messageText = "发现新版本 \(latest.tagName)"
            alert.informativeText = "当前版本 v\(currentVersion)。\n\n" + notesSummary(latest)
            alert.addButton(withTitle: "前往 GitHub 下载")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(latest.htmlURL) }
        case .upToDate:
            alert.messageText = "当前已是最新版本（v\(currentVersion)）"
            alert.addButton(withTitle: "查看 GitHub Releases")
            alert.addButton(withTitle: "好")
            if alert.runModal() == .alertFirstButtonReturn { openReleases() }
        }
    }

    private static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检查更新失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "前往 GitHub Releases")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn { openReleases() }
    }

    /// 更新说明只取开头一段纯文本，不渲染 Markdown。
    static func notesSummary(_ release: ReleaseInfo) -> String {
        let notes = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return release.name }
        return notes.count > notesLimit ? String(notes.prefix(notesLimit - 1)) + "…" : notes
    }
}
