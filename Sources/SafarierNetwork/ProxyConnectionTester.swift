import Foundation
import Darwin
import SafarierCore

public struct ProxyConnectionResult: Equatable, Sendable {
    public let exitIP: String
    public let duration: TimeInterval
    public let testedAt: Date

    public init(exitIP: String, duration: TimeInterval, testedAt: Date = Date()) {
        self.exitIP = exitIP
        self.duration = duration
        self.testedAt = testedAt
    }
}

public enum ProxyConnectionError: Error, LocalizedError {
    case missingPassword
    case proxyDNS
    case targetDNS
    case connection
    case authentication
    case handshake
    case timeout
    case tls
    case http(Int)
    case invalidResponse
    case transfer(Int32)

    public var errorDescription: String? {
        switch self {
        case .missingPassword: return "没有找到代理认证密码，请编辑代理并重新保存密码。"
        case .proxyDNS: return "无法解析代理服务器地址。"
        case .targetDNS: return "无法解析测试站点地址。"
        case .connection: return "无法连接代理服务器，请检查地址、端口及服务是否开启。"
        case .authentication: return "代理认证失败，请检查用户名和密码。"
        case .handshake: return "SOCKS5 握手或认证失败，请检查协议和认证信息。"
        case .timeout: return "连接测试超时，代理或测试站点没有及时响应。"
        case .tls: return "HTTPS 握手或证书校验失败。"
        case .http(let status): return "测试站点返回 HTTP \(status)，未确认 HTTPS 访问成功。"
        case .invalidResponse: return "测试响应无效，无法确认出口 IP。"
        case .transfer(let code): return "代理传输失败（错误码 \(code)），未回退直连。"
        }
    }
}

public enum ProxyConnectionTester {
    public static let endpoint = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!
    public typealias Test = @Sendable (ProxySettings, String?) async throws -> ProxyConnectionResult

    public static func check(proxy: ProxySettings, password: String?) async throws -> ProxyConnectionResult {
        try await check(proxy: proxy, password: password, target: endpoint, certificate: nil, timeout: 15)
    }

    /// 测试可注入本地 HTTPS 服务和专用 CA；产品入口始终使用系统证书校验和固定测试目标。
    static func check(proxy: ProxySettings, password: String?, target: URL, certificate: URL?, timeout: TimeInterval) async throws -> ProxyConnectionResult {
        let worker = Task.detached {
            try run(proxy: proxy, password: password, target: target, certificate: certificate, timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func run(proxy: ProxySettings, password: String?, target: URL, certificate: URL?, timeout: TimeInterval) throws -> ProxyConnectionResult {
        try proxy.validate()
        if proxy.username?.isEmpty == false, password == nil { throw ProxyConnectionError.missingPassword }
        guard target.scheme == "https" else { throw ProxyConnectionError.invalidResponse }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-proxy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let bodyURL = directory.appendingPathComponent("body")
        let metricsURL = directory.appendingPathComponent("metrics")
        guard FileManager.default.createFile(atPath: metricsURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: metricsURL)
        defer { try? output.close() }
        let input = Pipe()
        defer { try? input.fileHandleForReading.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = [
            "-q", "-fsS", "--proto", "=https", "--max-time", String(max(0.1, timeout)),
            "--connect-timeout", String(min(8, max(0.1, timeout))), "--max-filesize", "65536",
            "--output", bodyURL.path, "--write-out", "%{http_code}\n%{http_connect}\n%{time_total}\n", "-K", "-",
        ]
        if let certificate { arguments += ["--cacert", certificate.path] }
        process.arguments = arguments
        process.environment = ProxyGeoResolver.curlEnvironment
        process.standardInput = input
        process.standardOutput = output
        // 不显示 curl 原始错误，避免服务端响应或代理地址泄露认证信息。
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        guard ProxyGeoResolver.writeConfig(Data(ProxyGeoResolver.curlConfig(url: target.absoluteString, proxy: proxy, password: password).utf8), to: input.fileHandleForWriting) else {
            throw ProxyConnectionError.connection
        }
        let deadline = Date().addingTimeInterval(timeout + 2)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ProxyConnectionError.timeout }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        let metrics = try String(contentsOf: metricsURL, encoding: .utf8).split(separator: "\n")
        let status = metrics.first.flatMap { Int($0) } ?? 0
        let connectStatus = metrics.count > 1 ? Int(metrics[1]) ?? 0 : 0
        if connectStatus == 407 || status == 407 { throw ProxyConnectionError.authentication }
        switch process.terminationStatus {
        case 0: break
        case 5: throw ProxyConnectionError.proxyDNS
        case 6: throw ProxyConnectionError.targetDNS
        case 7: throw ProxyConnectionError.connection
        case 28: throw ProxyConnectionError.timeout
        case 35, 51, 58, 60: throw ProxyConnectionError.tls
        case 67: throw ProxyConnectionError.authentication
        case 97: throw ProxyConnectionError.handshake
        case 22: throw ProxyConnectionError.http(status)
        default: throw ProxyConnectionError.transfer(process.terminationStatus)
        }
        guard status == 200 else { throw ProxyConnectionError.http(status) }
        guard metrics.count == 3, let duration = Double(metrics[2]), duration.isFinite, duration >= 0,
              let body = try? String(contentsOf: bodyURL, encoding: .utf8),
              let line = body.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) else {
            throw ProxyConnectionError.invalidResponse
        }
        let ip = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr(), ipv6 = in6_addr()
        guard inet_pton(AF_INET, ip, &ipv4) == 1 || inet_pton(AF_INET6, ip, &ipv6) == 1 else {
            throw ProxyConnectionError.invalidResponse
        }
        return ProxyConnectionResult(exitIP: ip, duration: duration)
    }
}
