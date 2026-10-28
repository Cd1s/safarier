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

    /// Release-family mappings, not exact patch-build equivalence.
    /// Apple release notes: https://developer.apple.com/documentation/safari-release-notes
    /// In particular, 621.1/2/3 are Safari 18.4/5/6, not Safari 26.
    /// Expand each engine family for macOS 14, 15 and 26 bundle prefixes.
    public static let knownSafariVersions: [(webKitPrefix: String, safari: String)] = {
        let families: [(String, String)] = [
            ("616.1.", "17.0"), ("616.2.", "17.1"),
            ("617.1.", "17.2"), ("617.2.", "17.3"),
            ("618.1.", "17.4"), ("618.2.", "17.5"), ("618.3.", "17.6"),
            ("619.1.", "18.0"), ("619.2.", "18.1"),
            ("620.1.", "18.2"), ("620.2.", "18.3"),
            ("621.1.", "18.4"), ("621.2.", "18.5"), ("621.3.", "18.6"),
            ("622.1.", "26.0"), ("622.2.", "26.1"),
            ("623.1.", "26.2"), ("623.2.", "26.3"),
            ("624.1.", "26.4"), ("624.2.", "26.5"), ("624.4.", "26.6"),
            ("625.1.", "27.0"),
        ]
        return ["19", "20", "21"].flatMap { platform in
            families.map { (webKitPrefix: platform + $0.0, safari: $0.1) }
        }
    }()

    public static func engineBaseline(
        loadedWebKit: String? = systemWebKitVersion,
        installedSafari: String? = installedSafariVersion,
        safariStagedWebKit: String? = safariStagedWebKitVersion
    ) -> EngineBaselineDiagnostic {
        func nonEmpty(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let loaded = nonEmpty(loadedWebKit)
        let installed = nonEmpty(installedSafari)
        let staged = nonEmpty(safariStagedWebKit)
        func isBuild(_ value: String) -> Bool {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
        }
        let mapped = loaded.flatMap { version in
            isBuild(version) ? knownSafariVersions.first { version.hasPrefix($0.webKitPrefix) }?.safari : nil
        }
        let relationship: EngineBaselineDiagnostic.Relationship
        if let loaded, let staged, isBuild(loaded), isBuild(staged) {
            relationship = loaded == staged ? .sharedEngine : .stagedEngineMismatch
        } else {
            relationship = .unverified
        }
        let sharedVersion = relationship == .sharedEngine ? installed : nil
        let selected = sharedVersion ?? mapped ?? installed
        let matches = sharedVersion != nil || mapped != nil
        let comparison: String
        switch relationship {
        case .sharedEngine:
            comparison = "The loaded and staged engine builds match."
        case .stagedEngineMismatch:
            comparison = "Installed Safari uses a different staged engine; its version is not proof of the loaded engine's capabilities."
        case .unverified:
            comparison = "A loaded or staged engine build is missing; a shared engine has not been verified."
        }
        let selection = matches
            ? "UA selects Safari \(selected ?? "unknown") using \(sharedVersion == nil ? "a verified release-family mapping, not exact patch-build equivalence" : "the shared engine build")."
            : "No verified release mapping is available; any installed-version fallback remains unverified."
        let note = "loadedWebKit=\(loaded ?? "unknown"), installedSafari=\(installed ?? "unknown"), safariStagedWebKit=\(staged ?? "unknown"). \(comparison) \(selection)"
        return EngineBaselineDiagnostic(
            loadedWebKit: loaded, installedSafari: installed, safariStagedWebKit: staged,
            relationship: relationship, mappedSafariVersion: mapped, selectedSafariVersion: selected,
            matchesEngine: matches, note: note
        )
    }

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
        let baseline = engineBaseline(loadedWebKit: loadedWebKit, installedSafari: installedSafari, safariStagedWebKit: safariStagedWebKit)
        guard let version = baseline.selectedSafariVersion else { return nil }
        return UserAgentVersion(version: version, matchesEngine: baseline.matchesEngine, note: baseline.note)
    }

    /// Safari 的 UA 结尾是 `Version/<版本> Safari/605.1.15`（605.1.15 自 2017 年起冻结不变），
    /// WKWebView 默认没有这一段。没有可选版本时保持 WebKit 默认 UA。
    public static func safariApplicationNameForUserAgent(safariVersion: String? = userAgentSafariVersion()?.version) -> String? {
        guard let safariVersion, !safariVersion.isEmpty else { return nil }
        return "Version/\(safariVersion) Safari/605.1.15"
    }
}
