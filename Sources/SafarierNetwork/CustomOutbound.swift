import Foundation
import Darwin
import SafarierCore

public enum CustomOutboundError: Error, LocalizedError {
    case invalidJSON
    case invalidEndpoint
    case unsupportedStructure
    case checkFailed
    case checkTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "请填写合法的单个出站 JSON 对象。"
        case .invalidEndpoint: return "请填写服务器地址和 1–65535 之间的端口。"
        case .unsupportedStructure: return "仅支持单个代理出站，不支持完整配置、直连、出站组或 detour。"
        case .checkFailed: return "sing-box 校验失败，请检查协议字段及此版本支持的功能。原配置未保存。"
        case .checkTimedOut: return "sing-box 校验超时，原配置未保存。"
        }
    }
}

/// 仅开放单个出站；本地入站、标签和默认路由由应用维护。
public enum CustomOutbound {
    public static let defaultJSON = """
    {
      "type": "socks",
      "server": "127.0.0.1",
      "server_port": 1080,
      "version": "5"
    }
    """

    public static func parse(_ json: String) throws -> [String: SingboxJSONValue] {
        guard var outbound = try? JSONDecoder().decode([String: SingboxJSONValue].self, from: Data(json.utf8)) else {
            throw CustomOutboundError.invalidJSON
        }
        guard case .string(let type) = outbound["type"], !type.isEmpty,
              !["direct", "block", "dns", "selector", "urltest"].contains(type),
              ["inbounds", "outbounds", "route", "dns", "endpoints", "services", "detour"].allSatisfy({ outbound[$0] == nil }) else {
            throw CustomOutboundError.unsupportedStructure
        }
        guard case .string(let host) = outbound["server"],
              case .number(let port) = outbound["server_port"],
              (try? ProxySettings(name: "", kind: .socks5, host: host, port: port).validate()) != nil else {
            throw CustomOutboundError.invalidEndpoint
        }
        outbound["tag"] = .string(SingboxConfigBuilder.proxyTag)
        return outbound
    }

    public static func encoded(_ outbound: [String: SingboxJSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(outbound), as: UTF8.self)
    }

    public static func configuration(json: String, inboundPort: Int) throws -> SingboxConfiguration {
        try SingboxConfigBuilder.makeConfiguration(inboundPort: inboundPort, outbound: parse(json))
    }

    /// 在临时私有目录中检查完整运行配置。输出可能包含凭据，因此不回显原始 stderr。
    /// 校验不拨测节点是否可达；调用方在后台执行，成功后才保存返回的规范化 JSON。
    public static func checked(_ json: String, executableURL: URL = SingboxProcessManager.defaultExecutableURL) throws -> String {
        let normalized = try encoded(parse(json))
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SingboxProcessError.executableNotFound(executableURL)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.json")
        let data = try configuration(json: normalized, inboundPort: 1080).encoded()
        guard FileManager.default.createFile(atPath: configURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["check", "-c", configURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw CustomOutboundError.checkTimedOut
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CustomOutboundError.checkFailed }
        return normalized
    }
}
