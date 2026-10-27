import Foundation

/// 同一个二进制的三种身份，由命令行参数决定。
public enum ExecutableRole: Equatable, Sendable {
    /// 没有子命令（双击 .app、从访达打开、终端里直接运行）：图形管理器。
    case manager
    /// `run ...`：一个 profile 的 Runner 进程。
    case runner
    /// 其它子命令：命令行 Manager。
    case cli

    /// `arguments` 不含可执行文件路径本身。
    /// LaunchServices 可能追加 `-psn_0_xxx`，Xcode 会追加 `-NSXxx <value>` 这类 NSUserDefaults 参数；
    /// 只有这些参数时仍算"没有子命令"。
    public static func resolve(_ arguments: [String]) -> ExecutableRole {
        if arguments.first == RunnerLaunchSpec.subcommand { return .runner }
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg.hasPrefix("-psn_") {
                index += 1
            } else if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                index += 2
            } else {
                return .cli
            }
        }
        return .manager
    }
}
