import Foundation
#if os(macOS)
import CoreServices
import Darwin
#endif

/// 为浏览器下载落地的文件打上 macOS Gatekeeper 隔离属性（`com.apple.quarantine`），
/// 使可执行文件、脚本、安装包（.app / .dmg / .pkg）在双击运行时触发系统 Gatekeeper 安全提示，与真 Safari 行为一致。
/// 不把下载源 URL 写进系统全局的 `QuarantineEventsV2` 数据库，避免隔离环境或临时环境的浏览地址落入宿主机全局记录。
public enum DownloadQuarantine {
    public static let xattrName = "com.apple.quarantine"
    public static let defaultAgentName = "Safarier"
    public static let defaultBundleIdentifier = "sh.safarier.app"

    @discardableResult
    public static func apply(
        to fileURL: URL,
        agentName: String = defaultAgentName,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        #if os(macOS)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineAgentBundleIdentifierKey as String: bundleIdentifier,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
        if hasQuarantineAttribute(at: fileURL) {
            return true
        }
        let timestamp = String(Int(Date().timeIntervalSince1970), radix: 16)
        let sanitizedAgent = agentName.replacingOccurrences(of: ";", with: "")
        let fallback = "0081;\(timestamp);\(sanitizedAgent);"
        let bytes = Array(fallback.utf8)
        let result = fileURL.path.withCString { pathPtr in
            setxattr(pathPtr, xattrName, bytes, bytes.count, 0, 0)
        }
        return result == 0
        #else
        return false
        #endif
    }

    public static func hasQuarantineAttribute(at fileURL: URL) -> Bool {
        #if os(macOS)
        return fileURL.path.withCString { pathPtr in
            getxattr(pathPtr, xattrName, nil, 0, 0, 0) > 0
        }
        #else
        return false
        #endif
    }

    public static func quarantineValue(at fileURL: URL) -> String? {
        #if os(macOS)
        return fileURL.path.withCString { pathPtr -> String? in
            let size = getxattr(pathPtr, xattrName, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let readSize = getxattr(pathPtr, xattrName, &buffer, size, 0, 0)
            guard readSize > 0 else { return nil }
            return String(decoding: buffer.prefix(readSize), as: UTF8.self)
        }
        #else
        return nil
        #endif
    }
}
