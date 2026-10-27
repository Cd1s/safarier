import Foundation
import SafarierCore

// 同一个二进制三种身份：`run ...` 进入 Runner（一个 profile 一个进程），不带子命令进入图形管理器，
// 其它子命令是命令行 Manager。
let arguments = Array(CommandLine.arguments.dropFirst())

switch ExecutableRole.resolve(arguments) {
case .runner:
    MainActor.assumeIsolated {
        RunnerMain.start(arguments: arguments)
    }
case .manager:
    MainActor.assumeIsolated {
        ManagerGUI.start()
    }
case .cli:
    let status = MainActor.assumeIsolated {
        ManagerCLI.run(arguments)
    }
    exit(status)
}
