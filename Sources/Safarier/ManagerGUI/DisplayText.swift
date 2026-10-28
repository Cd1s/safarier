import Foundation
import SwiftUI
import SafarierCore
import SafarierNetwork

/// 界面上的文案和错误说明。
enum DisplayText {
    static func mode(_ mode: ProfileMode) -> String {
        switch mode {
        case .persistent: return "持久"
        case .ephemeral: return "临时"
        }
    }

    static func modeDetail(_ mode: ProfileMode) -> String {
        switch mode {
        case .persistent: return "Cookie、登录状态和缓存保存在磁盘，下次启动还在"
        case .ephemeral: return "数据只在内存里，关闭窗口即清空"
        }
    }

    static func proxyKind(_ kind: ProxyKind) -> String {
        switch kind {
        case .socks5: return "SOCKS5"
        case .httpConnect: return "HTTP CONNECT"
        }
    }

    static func proxyName(_ binding: ProxyBinding) -> String {
        switch binding {
        case .direct: return "直连"
        case .proxy(let proxy): return proxy.name
        case .missing: return "代理缺失"
        case .node(_, let node): return node.name
        case .missingNode: return "节点缺失"
        }
    }

    static func nodeType(_ type: SubscriptionNodeType) -> String {
        switch type {
        case .vless: return "VLESS"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .shadowsocks: return "SS"
        case .socks: return "SOCKS"
        case .anytls: return "AnyTLS"
        }
    }

    static func nodeColor(_ type: SubscriptionNodeType) -> Color {
        switch type {
        case .vless: return .purple
        case .vmess: return .blue
        case .trojan: return .red
        case .shadowsocks: return .teal
        case .socks: return .green
        case .anytls: return .orange
        }
    }

    static func spi(_ feature: SPIFeatures) -> (title: String, detail: String) {
        switch feature {
        case .fingerprintingProtections:
            return ("高级隐私保护", "开启 Safari 原生反指纹保护，对 Canvas、WebGL、Audio 采样按会话加噪，并隐藏真实窗口外框尺寸")
        case .engineTimeZone:
            return ("引擎层时区同步", "将网页与 Worker 内的 JavaScript 时区同步为当前环境的时区设置")
        case .disableWebRTC:
            return ("关闭 WebRTC", "禁用网页 RTCPeerConnection，防止绕过代理泄露真实 IP")
        case .safariAPIs:
            return ("Safari 专有接口与字体", "开启真 Safari 具备的 Apple Pay、推送、媒体设备接口，并像真 Safari 一样屏蔽用户自行安装的字体")
        case .webGPU:
            return ("WebGPU 硬件加速", "开启 navigator.gpu 接口（macOS 15 真 Safari 默认未开启，仅在网页需要时打开）")
        case .fontAllowlist:
            return ("按语言收窄字体", "按环境语言只向网页暴露对应系统的原生字体（已实测对齐真英文 Mac，英文、泰语等环境下自动隐藏宿主机下载的中日韩字体包）")
        default:
            return (feature.description, "")
        }
    }

    /// `1728×1117 pt（Retina 3456×2234 px）`
    static func viewport(_ model: MacDeviceModel) -> String {
        let points = "\(model.viewportWidth)×\(model.viewportHeight)"
        return model.scale == 1 ? "\(points) px" : "\(points) pt（Retina \(model.pixelWidth)×\(model.pixelHeight) px）"
    }

    static func hardware(_ model: MacDeviceModel) -> String {
        "\(model.cpuCores) 核 CPU · \(model.chip) \(model.gpuCores) 核 GPU"
    }

    /// 内建屏能力：P3 色域、HDR。
    /// `2560×1440 pt（可用 2560×1415）· P3 色域 · SDR`
    static func screen(_ model: MacDeviceModel) -> String {
        let traits: String
        switch (model.displayP3, model.displayHDR) {
        case (true, true): traits = "P3 色域 · HDR（XDR）"
        case (true, false): traits = "P3 色域 · SDR"
        default: traits = "sRGB · SDR（普通显示器）"
        }
        return "\(model.screenWidth)×\(model.screenHeight) pt（可用 \(model.availWidth)×\(model.availHeight)）· \(traits)"
    }

    /// 网页实际读到的值（和这款机型上的真 Safari 一致）。
    static func webVisible(_ model: MacDeviceModel) -> String {
        "\(MacDeviceModel.webVisibleCPUCores()) 核 · \(MacDeviceModel.webVisibleGPU) · devicePixelRatio \(model.scale)"
    }

    /// 机型模拟实际做了什么（2026-10-24 本机与真 Safari 对比实测）。
    static let deviceModelNote = "视口尺寸和纵横比、devicePixelRatio、显示器分辨率与可用区域、P3 色域和 HDR（网页的 color-gamut / dynamic-range 媒体查询）按机型设置，宿主机屏幕放不下时初始窗口等比缩小。高级隐私保护和机型互不影响：开启时网页的 screen 和 outer 尺寸随视口收敛，和真 Safari 无痕窗口一样；关闭时网页的 screen 报目标机型显示器的分辨率（台式机按搭配的显示器算），可用高度扣掉菜单栏。CPU 核数和 GPU 名称按真 Safari 的规则给：WebKit 只报 4 或 8 核、GPU 一律写「Apple GPU」，所以这几款机型在真 Safari 里都是 8 核 · Apple GPU，写成芯片规格反而露馅。"

    static let followProxy = "跟随代理（按出口 IP 自动匹配）"

    static func languages(_ languages: [String]) -> String {
        languages.isEmpty ? "跟随系统" : languages.joined(separator: ", ")
    }

    static func languages(of profile: Profile) -> String {
        profile.followProxyLanguages ? followProxy : languages(profile.languages)
    }

    static func timeZone(of profile: Profile) -> String {
        if profile.followProxyTimeZone { return followProxy }
        return profile.timeZoneIdentifier.map(timeZone) ?? "跟随系统"
    }

    /// 侧边栏用的短时区。
    static func shortTimeZone(of profile: Profile) -> String {
        if profile.followProxyTimeZone { return "跟随代理" }
        return profile.timeZoneIdentifier.map(shortTimeZone) ?? "系统时区"
    }

    /// `America/Los_Angeles` → `Los Angeles`，侧边栏用。
    static func shortTimeZone(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// `America/Los_Angeles（UTC−7）`
    static func timeZone(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        return "\(identifier)（\(utcOffset(zone))）"
    }

    static func utcOffset(_ zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT()
        let sign = seconds < 0 ? "−" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        return minutes == 0 ? "UTC\(sign)\(hours)" : String(format: "UTC%@%d:%02d", sign, hours, minutes)
    }

    /// 持久 data store 在磁盘上的位置：WebKit 按 bundle id（裸二进制按进程名）分目录，
    /// 所以从 Safarier.app 和从 .build 里的二进制启动，数据不在同一个地方。
    static func webKitDataDirectory(for profileID: UUID) -> URL {
        let owner = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/\(owner)/WebsiteDataStore/\(profileID.uuidString)", isDirectory: true)
    }

    /// 「导入 12 个节点；跳过 3 个暂不支持的节点（hysteria2 ×2、tuic ×1）。」
    static func importSummary(_ result: SubscriptionParseResult) -> String {
        var text = "导入 \(result.nodes.count) 个节点"
        if result.skippedCount > 0 {
            let detail = result.skippedSchemes.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: "、")
            text += "；跳过 \(result.skippedCount) 个暂不支持的节点（\(detail)）"
        }
        return text + "。"
    }

    /// 错误说明。订阅解析错误里可能带着整行链接（含密码），这里只显示协议名。
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as ProfileValidationError:
            switch error {
            case .emptyName: return "名称不能为空。"
            case .nameTooLong(let count): return "名称太长（\(count) 个字符，最多 64）。"
            case .invalidLanguageTag(let tag): return "语言标签不合法：\(tag)（例如 en-US）。"
            case .unknownTimeZone(let identifier): return "未知时区：\(identifier)。"
            case .unsupportedStartURLScheme(let scheme): return "起始网址只能是 http 或 https，现在是「\(scheme)」。"
            case .conflictingOutbound: return "独立代理和订阅节点只能选一个。"
            case .missingNodeName: return "请选择订阅里的节点。"
            case .unknownDeviceModel(let id): return "未知机型：\(id)。"
            }
        case let error as SubscriptionValidationError:
            switch error {
            case .emptyName: return "订阅名称不能为空。"
            case .nameTooLong(let count): return "订阅名称太长（\(count) 个字符，最多 128）。"
            case .unsupportedURLScheme(let scheme): return "订阅链接只能是 http、https 或 file，现在是「\(scheme)」。"
            case .invalidURL: return "订阅链接缺少主机名。"
            }
        case let error as SubscriptionNodeValidationError:
            return "订阅里有不完整的节点：\(error)。"
        case let error as SubscriptionParseError:
            switch error {
            case .invalidLine(let line):
                let scheme = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "?"
                return "订阅里有一行无法解析（\(scheme)://…）。"
            case .invalidBase64: return "订阅内容既不是 UTF-8 文本，也不是合法的 Base64。"
            case .invalidJSON: return "VMess 节点的 JSON 无法解析。"
            case .unsupportedScheme(let scheme): return "不支持的节点协议：\(scheme)。"
            }
        case let error as SubscriptionFetchError:
            switch error {
            case .invalidHTTPStatus(let code): return "订阅服务器返回 HTTP \(code)。"
            }
        case let error as InlineSubscriptionError:
            switch error {
            case .noNodes: return "没有找到节点链接。"
            case .unrecognized: return "既不是订阅网址（https://…），也不是节点链接（ss:// vless:// 等）或 Base64 订阅内容。"
            }
        case let error as WorkspaceError:
            switch error {
            case .alreadyRunning: return "这个环境已经在运行。"
            case .subscriptionNotFound: return "绑定的订阅已经不存在。"
            case .nodeNotFound(let subscription, let node): return "订阅「\(subscription)」里没有节点「\(node)」。"
            }
        case let error as SingboxProcessError:
            return error.description
        case let error as RepositoryError:
            switch error {
            case .duplicateID: return "已经有相同 ID 的记录。"
            case .notFound: return "记录不存在，可能已经在别处删除。"
            }
        default:
            return (error as NSError).localizedDescription
        }
    }
}
