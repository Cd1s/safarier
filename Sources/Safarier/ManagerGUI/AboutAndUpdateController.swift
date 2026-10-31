import AppKit
import Foundation
import SafarierCore

/// 「关于 Safarier」「检查更新…」和 GitHub 页面入口，管理器和浏览器窗口共用。
@MainActor
enum AboutAndUpdateController {
    /// 调用方所在的进程。浏览器进程里的直连请求不走环境的代理（会泄露真实 IP），所以那边的「检查更新」只打开 Releases 页面，不发请求。
    enum Context {
        case manager
        case browser
    }

    static let fallbackVersion = "1.2.3"
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
            alert.addButton(withTitle: "立即更新并重启")
            alert.addButton(withTitle: "查看更新内容")
            alert.addButton(withTitle: "查看 GitHub 项目")
            alert.addButton(withTitle: "稍后")
            switch alert.runModal() {
            case .alertFirstButtonReturn: startInstall(latest)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(latest.htmlURL)
            case .alertThirdButtonReturn: openGitHub()
            default: break
            }
        case .upToDate:
            alert.messageText = "当前已是最新版本（v\(currentVersion)）"
            alert.addButton(withTitle: "查看 GitHub Releases")
            alert.addButton(withTitle: "好")
            if alert.runModal() == .alertFirstButtonReturn { openReleases() }
        }
    }

    private static func startInstall(_ release: ReleaseInfo) {
        Task { @MainActor in
            do {
                try await installUpdateAndRelaunch(release)
            } catch {
                presentFailure(error, title: "更新失败")
            }
        }
    }

    private static func presentFailure(_ error: Error, title: String = "检查更新失败") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
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

    // MARK: - 下载、校验、替换并重启

    enum InstallError: LocalizedError {
        case checksumMismatch
        case checksumDownloadFailed
        case downloadFailed(Int)
        case commandFailed(String, String)
        case appMissing

        var errorDescription: String? {
            switch self {
            case .checksumMismatch: return "下载内容的 SHA-256 与发布的校验值不一致，已放弃安装"
            case .checksumDownloadFailed: return "无法获取 SHA-256 校验文件，已放弃安装"
            case .downloadFailed(let code): return "下载失败（HTTP \(code)）"
            case .commandFailed(let tool, let detail): return "\(tool) 执行失败：\(detail)"
            case .appMissing: return "更新包里没有 Safarier.app"
            }
        }
    }

    #if arch(arm64)
    static let currentArch = "arm64"
    #else
    static let currentArch = "x86_64"
    #endif

    /// 下载当前架构的 zip → 核对 SHA-256 → 解压 → 去隔离属性并验签 → 替换正在运行的 .app → 重新打开并退出。
    /// 只在管理器进程里调用（直连 GitHub，和「检查更新」一样）。没有可用的 zip 时退回打开 Release 页面。
    /// 有 `.sha256` 资产就必须校验通过；不匹配一律抛错，不会安装。
    static func installUpdateAndRelaunch(_ release: ReleaseInfo, onProgress: ((String) -> Void)? = nil) async throws {
        guard let zipAsset = release.preferredZipAsset(arch: currentArch) else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        onProgress?("正在下载 \(zipAsset.name)…")
        let zipData = try await download(zipAsset.downloadURL, session: session)
        if let shaAsset = release.sha256Asset(for: zipAsset) {
            onProgress?("正在校验 SHA-256…")
            guard let shaData = try? await download(shaAsset.downloadURL, session: session),
                  let shaText = String(data: shaData, encoding: .utf8) else { throw InstallError.checksumDownloadFailed }
            guard UpdateChecker.verifySHA256(data: zipData, expectedFileText: shaText) else { throw InstallError.checksumMismatch }
        }

        let workDir = URL(fileURLWithPath: "/private/tmp/safarier-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = workDir.appendingPathComponent("update.zip")
        try zipData.write(to: zipURL, options: .atomic)

        onProgress?("正在解压并验证签名…")
        let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        try await run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extracted.path])
        let newApp = extracted.appendingPathComponent("Safarier.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw InstallError.appMissing }
        try await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

        onProgress?("正在替换并重启…")
        let target = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL
            : URL(fileURLWithPath: "/Applications/Safarier.app", isDirectory: true)
        // 先在同一目录里摆好新包再原子替换，中途失败不会丢掉旧版本。
        let staged = target.deletingLastPathComponent().appendingPathComponent(".Safarier-update-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.copyItem(at: newApp, to: staged)
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "(sleep 0.5; /usr/bin/open -n \"$1\") >/dev/null 2>&1 &", "sh", target.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    private static func download(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Safarier/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw InstallError.downloadFailed(http.statusCode) }
        return data
    }

    /// 在后台线程跑系统工具，非 0 退出就把 stderr 带进错误里。
    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderr
                do {
                    try process.run()
                    let output = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let detail = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(throwing: InstallError.commandFailed((tool as NSString).lastPathComponent, detail.isEmpty ? "退出码 \(process.terminationStatus)" : detail))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
