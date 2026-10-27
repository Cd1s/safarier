import WebKit
import SafarierCore

/// SafarierWebKit 模块：只用公开 WebKit / Network API。
public enum SafarierWebKitInfo {
    /// 当前进程实际加载的 WebKit 版本（例如 "20621.3.11.11.3"）。
    public static var systemWebKitVersion: String? {
        Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// 本机安装的 Safari 版本（例如 "27.0"）。
    public static var installedSafariVersion: String? {
        Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 旧版 macOS 上更新 Safari 时，新版 WebKit 装在 App Cryptex 里，只有 Safari 能加载：
    /// 第三方进程映射它会被内核拦下（"file system sandbox blocked mmap()"，2026-10-24 macOS 15.7.3 实测，
    /// DYLD_FRAMEWORK_PATH 和 LC_DYLD_ENVIRONMENT 都无效）。所以 WKWebView 用的仍是系统 WebKit。
    public static let safariStagedWebKitURL = URL(fileURLWithPath: "/System/Cryptexes/App/System/Library/StagedFrameworks/Safari/WebKit.framework")

    public static var safariStagedWebKitVersion: String? {
        Bundle(url: safariStagedWebKitURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// 系统 WebKit 版本前缀 → 用同一内核的 Safari 版本。
    /// 20621.3：本机 softwareupdate 记录里 Safari 26.2 与 macOS 15.7.3 同批安装（2026-01-19），系统 WebKit 即 20621.3.11。
    public static let knownSafariVersions: [(webKitPrefix: String, safari: String)] = [
        ("20621.3.", "26.2"),
    ]

    public struct UserAgentVersion: Equatable, Sendable {
        public var version: String
        /// UA 版本和实际加载的内核对得上。
        public var matchesEngine: Bool
        public var note: String
    }

    /// UA 里写哪个 Safari 版本：Safari 和我们用同一个 WebKit 时写已安装的 Safari 版本；
    /// Safari 用的是它专用的新版 WebKit 时，写和我们这个内核对应的 Safari 版本，免得"UA 是新版、内核是旧版"。
    public static func userAgentSafariVersion(
        loadedWebKit: String? = systemWebKitVersion,
        installedSafari: String? = installedSafariVersion,
        safariStagedWebKit: String? = safariStagedWebKitVersion
    ) -> UserAgentVersion? {
        guard let installedSafari, !installedSafari.isEmpty else { return nil }
        guard let staged = safariStagedWebKit, let loaded = loadedWebKit, staged != loaded else {
            return UserAgentVersion(version: installedSafari, matchesEngine: true, note: "Safari \(installedSafari) 与本进程用同一个 WebKit")
        }
        if let known = knownSafariVersions.first(where: { loaded.hasPrefix($0.webKitPrefix) }) {
            return UserAgentVersion(
                version: known.safari,
                matchesEngine: true,
                note: "已装的 Safari \(installedSafari) 用的是它专用的 WebKit \(staged)，第三方应用加载不了；本进程是 WebKit \(loaded)，对应 Safari \(known.safari)"
            )
        }
        return UserAgentVersion(
            version: installedSafari,
            matchesEngine: false,
            note: "已装的 Safari \(installedSafari) 用 WebKit \(staged)，本进程是 WebKit \(loaded)，没有对应的 Safari 版本记录，UA 与内核可能不一致"
        )
    }

    /// Safari 的 UA 结尾是 `Version/<版本> Safari/605.1.15`（605.1.15 自 2017 年起冻结不变），
    /// WKWebView 默认没有这一段。返回 nil 表示找不到本机 Safari，此时保持 WebKit 默认 UA。
    public static func safariApplicationNameForUserAgent(safariVersion: String? = userAgentSafariVersion()?.version) -> String? {
        guard let safariVersion, !safariVersion.isEmpty else { return nil }
        return "Version/\(safariVersion) Safari/605.1.15"
    }
}
