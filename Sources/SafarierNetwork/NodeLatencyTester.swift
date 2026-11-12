import Foundation
import Darwin
import SafarierCore

public extension ProxyConnectionTester {
    /// Node tests use a shorter deadline than a saved proxy's full connection diagnostic.
    static let nodeTimeout: TimeInterval = 8
    typealias NodeTestUpdate = @Sendable (UUID, Result<ProxyConnectionResult, Error>) async -> Void
    typealias NodeBatchTest = @Sendable ([SubscriptionNode], @escaping NodeTestUpdate) async throws -> Void

    static func check(nodes: [SubscriptionNode], update: @escaping NodeTestUpdate) async throws {
        try await check(nodes: nodes, executableURL: SingboxProcessManager.defaultExecutableURL,
                        target: endpoint, certificate: nil, timeout: nodeTimeout, update: update)
    }

    /// One sing-box and one parallel curl process serve the whole batch. Results stream as each
    /// request completes; neither slow nodes nor curl's final exit status hide successful peers.
    static func check(
        nodes: [SubscriptionNode], executableURL: URL, target: URL, certificate: URL?, timeout: TimeInterval,
        stateDirectory: URL? = nil, update: @escaping NodeTestUpdate
    ) async throws {
        var seen = Set<UUID>()
        var valid: [SubscriptionNode] = []
        for node in nodes where seen.insert(node.id).inserted {
            try Task.checkCancellation()
            do { try node.validate(); valid.append(node) }
            catch { await update(node.id, .failure(error)) }
        }
        guard !valid.isEmpty else { return }
        // Finder-launched apps can inherit a 256-file soft limit. Parallel sockets and response
        // files need more room; only raise this process's soft limit, preserving the hard limit.
        var limits = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limits) == 0 {
            let desired = min(limits.rlim_max, rlim_t(max(1_024, valid.count * 4 + 64)))
            if limits.rlim_cur < desired {
                limits.rlim_cur = desired
                _ = setrlimit(RLIMIT_NOFILE, &limits)
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            let native = valid.filter { $0.type != .mieru }
            if !native.isEmpty {
                group.addTask {
                    try await checkBatch(nodes: native, executableURL: executableURL, target: target,
                                         certificate: certificate, timeout: timeout,
                                         stateDirectory: stateDirectory, update: update)
                }
            }
            // Mieru uses its own executable, so it retains a dedicated bridge per node.
            for node in valid where node.type == .mieru {
                group.addTask {
                    do {
                        let result = try await check(node: node, executableURL: executableURL) { proxy, password in
                            try await check(proxy: proxy, password: password, target: target,
                                            certificate: certificate, timeout: timeout)
                        }
                        await update(node.id, .success(result))
                    } catch is CancellationError { throw CancellationError() }
                    catch { await update(node.id, .failure(error)) }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Also used by injected executors in the manager's concurrency tests.
    static func checkConcurrently(nodes: [SubscriptionNode], using tester: @escaping NodeTest,
                                  update: @escaping NodeTestUpdate) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    do { await update(node.id, .success(try await tester(node))) }
                    catch is CancellationError { throw CancellationError() }
                    catch { await update(node.id, .failure(error)) }
                }
            }
            try await group.waitForAll()
        }
    }

    private static func checkBatch(
        nodes: [SubscriptionNode], executableURL: URL, target: URL, certificate: URL?, timeout: TimeInterval,
        stateDirectory: URL?, update: @escaping NodeTestUpdate
    ) async throws {
        let directory = (stateDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("safarier-node-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let manager = SingboxProcessManager(executableURL: executableURL, stateDirectory: directory)
        defer {
            manager.stopAll()
            try? FileManager.default.removeItem(at: directory)
        }
        let id = UUID()
        let password = UUID().uuidString
        let startup = Task.detached {
            try Task.checkCancellation()
            let port = try manager.port(for: id)
            let configuration = try nodeTestConfiguration(nodes: nodes, inboundPort: port, password: password)
            try manager.start(profileID: id, configuration: configuration)
            return try manager.waitUntilReady(profileID: id, timeout: 5)
        }
        let port = try await withTaskCancellationHandler {
            try await startup.value
        } onCancel: { startup.cancel() }
        try Task.checkCancellation()
        try await runParallel(nodes: nodes, port: port, password: password, target: target,
                              certificate: certificate, timeout: timeout, directory: directory, update: update)
    }

    /// A separate authenticated SOCKS user selects each outbound, allowing one listener without
    /// port allocation races. Unmatched traffic is rejected; there is no direct outbound.
    static func nodeTestConfiguration(nodes: [SubscriptionNode], inboundPort: Int, password: String) throws -> SingboxConfiguration {
        guard (1...65535).contains(inboundPort) else { throw SingboxConfigError.invalidInboundPort(inboundPort) }
        var outbounds: [[String: SingboxJSONValue]] = []
        var rules: [SingboxJSONValue] = []
        var users: [SingboxJSONValue] = []
        for node in nodes {
            try node.validate()
            guard node.type != .mieru else { throw SingboxConfigError.mieruRequiresBridge }
            let key = node.id.uuidString
            var outbound = SingboxConfigBuilder.makeOutbound(node)
            outbound["tag"] = .string(key)
            outbounds.append(outbound)
            users.append(.object(["username": .string(key), "password": .string(password)]))
            rules.append(.object(["auth_user": .array([.string(key)]),
                                  "action": .string("route"), "outbound": .string(key)]))
        }
        rules.append(.object(["action": .string("reject")]))
        return SingboxConfiguration(
            log: ["level": .string("error")],
            inbounds: [["type": .string("socks"), "tag": .string("node-tests"),
                        "listen": .string("127.0.0.1"), "listen_port": .number(inboundPort), "users": .array(users)]],
            outbounds: outbounds, route: ["rules": .array(rules)],
            dns: outbounds.contains { $0["domain_resolver"] != nil }
                ? ["servers": .array([.object(["type": .string("local"), "tag": .string("node-dns")])])] : nil
        )
    }

    private static func runParallel(
        nodes: [SubscriptionNode], port: Int, password: String, target: URL, certificate: URL?,
        timeout: TimeInterval, directory: URL, update: @escaping NodeTestUpdate
    ) async throws {
        guard target.scheme == "https" else { throw ProxyConnectionError.invalidResponse }
        try Task.checkCancellation()
        let metricsURL = directory.appendingPathComponent("metrics")
        guard FileManager.default.createFile(atPath: metricsURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: metricsURL)
        let reader = try FileHandle(forReadingFrom: metricsURL)
        defer { try? output.close(); try? reader.close() }
        var config: [String] = []
        for node in nodes {
            let key = node.id.uuidString
            let local = ProxySettings(name: "Node test", kind: .socks5, host: "127.0.0.1", port: port, username: key)
            var entry = ProxyGeoResolver.curlConfig(url: target.absoluteString, proxy: local, password: password)
            entry += "silent\nfail\nproto = \"=https\"\nmax-filesize = 65536\n"
            entry += "max-time = \"\(max(0.1, timeout))\"\nconnect-timeout = \"\(min(5, max(0.1, timeout)))\"\n"
            let bodyURL = directory.appendingPathComponent(key)
            guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            entry += "output = \"\(ProxyGeoResolver.curlEscape(bodyURL.path))\"\n"
            // stderr is unbuffered, so a fast node appears before the slowest one finishes.
            entry += "write-out = \"%{stderr}\(key)\\t%{exitcode}\\t%{http_code}\\t%{http_connect}\\t%{time_total}\\n\"\n"
            if let certificate { entry += "cacert = \"\(ProxyGeoResolver.curlEscape(certificate.path))\"\n" }
            config.append(entry)
        }
        let input = Pipe()
        defer { try? input.fileHandleForReading.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "--parallel", "--parallel-immediate", "--parallel-max", String(min(10_000, nodes.count)), "-K", "-"]
        process.environment = ProxyGeoResolver.curlEnvironment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        guard ProxyGeoResolver.writeConfig(Data(config.joined(separator: "next\n").utf8), to: input.fileHandleForWriting) else {
            throw ProxyConnectionError.connection
        }
        var pending = Set(nodes.map(\.id))
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout + 2)
        while true {
            try Task.checkCancellation()
            let running = process.isRunning
            buffer.append(try reader.readToEnd() ?? Data())
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 5, let key = UUID(uuidString: String(fields[0])),
                      let code = Int32(fields[1]), pending.remove(key) != nil else { continue }
                let result = Result {
                    try readResult(exitCode: code, metrics: fields.dropFirst(2).joined(separator: "\n"),
                                   bodyURL: directory.appendingPathComponent(key.uuidString))
                }
                await update(key, result)
            }
            if !running { break }
            guard Date() < deadline else { throw ProxyConnectionError.timeout }
            try await Task.sleep(for: .milliseconds(25))
        }
        process.waitUntilExit()
        for key in pending {
            await update(key, .failure(ProxyConnectionError.transfer(process.terminationStatus)))
        }
    }
}
