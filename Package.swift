// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Safarier",
    platforms: [
        // 公开 API 最低要求。WKWebsiteDataStore(forIdentifier:) 等需要 macOS 14。
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Safarier", targets: ["Safarier"]),
        .library(name: "SafarierCore", targets: ["SafarierCore"]),
        .library(name: "SafarierNetwork", targets: ["SafarierNetwork"]),
        .library(name: "SafarierWebKit", targets: ["SafarierWebKit"]),
    ],
    targets: [
        // 只依赖 Foundation/Security：Profile、代理、存储、凭据、Runner 启动协议、能力报告。
        .target(name: "SafarierCore"),
        // sing-box process lifecycle and subscription parsing.
        .target(name: "SafarierNetwork", dependencies: ["SafarierCore"]),
        // 动态调用私有接口的最小 ObjC 层：先检查 selector 和类型编码，再在 @try 里调用，NSException 不进 Swift。
        .target(name: "SafarierObjCSupport"),
        // 公开 WebKit/Network API：DataStore、代理配置、WKWebViewConfiguration 组装。
        // 私有接口只出现在可选的 SPIPrivacyAdapter 里，经 SafarierObjCSupport 动态探测、失败降级。
        .target(name: "SafarierWebKit", dependencies: ["SafarierCore", "SafarierObjCSupport"]),
        // 命令行 Manager + AppKit Runner（同一个二进制，`run` 子命令进入 Runner 模式）。
        .executableTarget(name: "Safarier", dependencies: ["SafarierCore", "SafarierNetwork", "SafarierWebKit"]),
        .testTarget(name: "SafarierCoreTests", dependencies: ["SafarierCore"]),
        .testTarget(name: "SafarierNetworkTests", dependencies: ["SafarierNetwork", "SafarierCore"]),
        .testTarget(name: "SafarierWebKitTests", dependencies: ["SafarierWebKit", "SafarierObjCSupport"]),
        // 浏览窗口（可执行目标里的 AppKit 代码）：多标签 / 多窗口释放、窗口尺寸回调、地址栏焦点。
        .testTarget(name: "SafarierAppTests", dependencies: ["Safarier", "SafarierCore", "SafarierWebKit"]),
    ]
)
