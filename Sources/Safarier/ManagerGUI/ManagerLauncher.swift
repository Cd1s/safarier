import AppKit
import Foundation
import SafarierCore

/// 跨进程唤醒或拉起图形管理器：
/// 1. 管理器在同工作目录下存活时，发本机唤醒通知并激活该进程，避免双开；
/// 2. 管理器未运行（例如已被 ⌘Q 退出或仅由 CLI 拉起浏览器）时，在 `.app` 下以多实例模式启动新管理器，
///    裸二进制开发模式下回落为直接拉起当前可执行文件（无参数即进入图形管理器）。
@MainActor
enum ManagerLauncher {
    enum ActionResult: Equatable {
        case wokeRunningManager(pid: Int32)
        case launchedAppBundle(URL)
        case launchedRawExecutable(URL)
        case failed
    }

    struct Environment {
        var managerPID: () -> Int32?
        var isProcessAlive: (Int32) -> Bool
        var postWakeupNotification: (String) -> Void
        var activateProcess: (Int32) -> Bool
        var bundleURL: () -> URL
        var executableURL: () -> URL
        var processEnvironment: () -> [String: String]
        var openAppBundle: (URL, [String: String]) -> Void
        var spawnExecutable: (URL, [String: String]) throws -> Void
    }

    static func liveEnvironment(workspace: SafarierWorkspace) -> Environment {
        Environment(
            managerPID: { workspace.managerPID() },
            isProcessAlive: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                return !app.isTerminated
            },
            postWakeupNotification: { scope in
                postWakeupNotification(scope: scope)
            },
            activateProcess: { pid in
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) ?? false
            },
            bundleURL: { Bundle.main.bundleURL },
            executableURL: { RunnerLauncher.currentExecutableURL() },
            processEnvironment: { ProcessInfo.processInfo.environment },
            openAppBundle: { bundle, env in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.activates = true
                if let home = env["SAFARIER_HOME"], !home.isEmpty {
                    configuration.environment = ["SAFARIER_HOME": home]
                }
                NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in }
            },
            spawnExecutable: { executable, env in
                let process = Process()
                process.executableURL = executable
                process.arguments = []
                process.environment = env
                try process.run()
            }
        )
    }

    static func postWakeupNotification(scope: String) {
        DistributedNotificationCenter.default().postNotificationName(
            ManagerWakeup.notificationName,
            object: scope,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// 供重复启动的管理器进程直接唤醒已有管理器。
    static func wakeExistingManager(pid: Int32?, workspace: SafarierWorkspace) {
        postWakeupNotification(scope: workspace.managerWakeupScope)
        if let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            _ = app.activate(options: [.activateAllWindows])
        }
    }

    @discardableResult
    static func openOrWakeManager(
        workspace: SafarierWorkspace,
        environment: Environment? = nil
    ) -> ActionResult {
        let env = environment ?? liveEnvironment(workspace: workspace)
        let scope = workspace.managerWakeupScope

        if let pid = env.managerPID(), env.isProcessAlive(pid) {
            env.postWakeupNotification(scope)
            _ = env.activateProcess(pid)
            return .wokeRunningManager(pid: pid)
        }

        let currentEnv = env.processEnvironment()
        let bundle = env.bundleURL()
        if bundle.pathExtension == "app" {
            env.openAppBundle(bundle, currentEnv)
            return .launchedAppBundle(bundle)
        }

        let executable = env.executableURL()
        do {
            try env.spawnExecutable(executable, currentEnv)
            return .launchedRawExecutable(executable)
        } catch {
            return .failed
        }
    }
}
