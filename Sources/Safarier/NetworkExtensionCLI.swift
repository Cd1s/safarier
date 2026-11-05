import Foundation
import NetworkExtension
import SystemExtensions
import SafarierProxyControl

/// Explicit developer command only. Launching a profile never installs or enables a system extension.
@MainActor
enum NetworkExtensionCLI {
    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1, ["install", "status"].contains(arguments[0]) else {
            print("用法：safarier network-extension install|status"); return 64
        }
        guard #available(macOS 15.0, *) else { print("网络扩展需要 macOS 15 或更新版本"); return 1 }
        let operation = ExtensionOperation()
        if arguments[0] == "status" { operation.status() }
        else {
            guard (try? ProxyExtensionIdentity.team()) != nil,
                  Bundle.main.bundleIdentifier == ProxyExtensionIdentity.hostID,
                  FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(ProxyExtensionIdentity.extensionID).systemextension").path) else {
                print("请从包含签名网络扩展的 Safarier.app 运行；普通 ad-hoc 构建不支持安装。")
                return 1
            }
            operation.install()
        }
        let deadline = Date().addingTimeInterval(120)
        while operation.result == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if operation.result == nil { print("等待系统扩展操作超时；未确认扩展就绪。") }
        return operation.result ?? 1
    }
}

@available(macOS 15.0, *)
@MainActor
private final class ExtensionOperation: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    var result: Int32?
    private var request: OSSystemExtensionRequest?
    func status() {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                guard error == nil else { self.finish("读取网络扩展配置失败", 1); return }
                let own = (managers ?? []).filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == ProxyExtensionIdentity.extensionID }
                guard !own.isEmpty else { self.finish("未配置实验网络扩展（未做任何修改）", 0); return }
                for manager in own {
                    print("enabled=\(manager.isEnabled) vpnStatus=\(manager.connection.status.rawValue)")
                }
                self.finish("配置状态不代表媒体路由已验证；Runner 仍须通过 XPC 注册。", 0)
            }
        }
    }
    func install() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: ProxyExtensionIdentity.extensionID, queue: .main)
        self.request = request; request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        finish("请在系统设置批准 Safarier 网络扩展后重新执行 install；尚未创建或启动代理配置。", 2)
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish("系统扩展激活失败：\((error as NSError).domain) / \((error as NSError).code)", 1)
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard self.result == nil else { return }
        guard result == .completed else { finish("系统要求重启；重启后重新执行 install。尚未启动代理配置。", 2); return }
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                guard error == nil else { self.finish("读取代理配置失败", 1); return }
                let own = (managers ?? []).filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == ProxyExtensionIdentity.extensionID }
                guard own.count <= 1 else { self.finish("发现多个 Safarier 代理配置，请先在系统设置检查；未修改配置。", 1); return }
                let manager = own.first ?? NETransparentProxyManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = ProxyExtensionIdentity.extensionID
                proto.serverAddress = "127.0.0.1"
                manager.protocolConfiguration = proto
                manager.localizedDescription = "Safarier WebRTC Proxy (Experimental)"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    guard error == nil else { DispatchQueue.main.async { self.finish("保存代理配置失败", 1) }; return }
                    manager.loadFromPreferences { error in
                        DispatchQueue.main.async {
                            guard error == nil else { self.finish("重新读取代理配置失败", 1); return }
                            do {
                                try manager.connection.startVPNTunnel()
                                self.finish("已请求启动实验网络扩展；首次使用前仍须完成签名媒体与失效测试。", 0)
                            } catch { self.finish("代理启动失败", 1) }
                        }
                    }
                }
            }
        }
    }
    private func finish(_ message: String, _ result: Int32) {
        guard self.result == nil else { return }; print(message); self.result = result
    }
}
