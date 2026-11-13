import Foundation
import XCTest
@testable import SafarierNetwork

final class SubscriptionFetcherTests: XCTestCase {
    func testFetchParsesClashResponseDespiteURIClientUserAgent() async throws {
        let (fetcher, url) = makeFetcher(format: "clash")
        let result = try await fetcher.fetchResult(from: url)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.type.rawValue, "hysteria2")
        XCTAssertEqual(result.nodes.first?.parameters["server_ports"], "20000:30000,443:443")
        XCTAssertEqual(requests(for: url).map(\.route), ["system"])
    }

    func testFetchSendsClientUserAgentAndParsesSubscription() async throws {
        let (fetcher, url) = makeFetcher()
        let result = try await fetcher.fetchResult(from: url)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.server, "proxy.example")
        XCTAssertEqual(result.nodes.first?.serverPort, 1080)
        XCTAssertEqual(requests(for: url).map(\.route), ["system"])
        XCTAssertEqual(requests(for: url).first?.request.value(forHTTPHeaderField: "User-Agent"), "Shadowrocket")
    }

    func testForbiddenResponseAutomaticallyRetriesDirectWithSameRequest() async throws {
        let (fetcher, url) = makeFetcher(system: "403", timeout: 12)
        let result = try await fetcher.fetchResult(from: url)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.server, "proxy.example")
        let attempts = requests(for: url)
        XCTAssertEqual(attempts.map(\.route), ["system", "direct"])
        for attempt in attempts {
            XCTAssertEqual(attempt.request.url, url, "直连重试保留原始订阅地址和认证参数")
            XCTAssertEqual(attempt.request.value(forHTTPHeaderField: "User-Agent"), "Shadowrocket")
            XCTAssertEqual(attempt.request.timeoutInterval, 12)
        }
    }

    func testDirectRetryParsesClashSubscription() async throws {
        let (fetcher, url) = makeFetcher(system: "403", format: "clash")
        let result = try await fetcher.fetchResult(from: url)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.type.rawValue, "hysteria2")
        XCTAssertEqual(result.nodes.first?.parameters["server_ports"], "20000:30000,443:443")
        XCTAssertEqual(requests(for: url).map(\.route), ["system", "direct"])
    }

    func testDirectRetryParsesSubscriptionWithShadowrocketStatusHeader() async throws {
        let (fetcher, url) = makeFetcher(system: "403", format: "shadowrocket")
        let result = try await fetcher.fetchResult(from: url)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.server, "proxy.example")
        XCTAssertEqual(requests(for: url).map(\.route), ["system", "direct"])
    }

    func testSkippedHysteriaNodesAutomaticallyRequestCompleteClashFormat() async throws {
        let (fetcher, url) = makeFetcher(format: "mixed-hysteria")
        let result = try await fetcher.fetchResult(from: url)

        XCTAssertEqual(result.nodes.map(\.name), ["Example", "Hysteria"])
        XCTAssertEqual(result.nodes.map(\.type.rawValue), ["socks", "hysteria2"])
        XCTAssertTrue(result.skippedSchemes.isEmpty)
        let hysteria = try XCTUnwrap(result.nodes.last)
        XCTAssertEqual(hysteria.parameters["server_ports"], "20000:30000")
        XCTAssertEqual(hysteria.parameters["obfs-password"], "sample-obfs")
        XCTAssertEqual(hysteria.parameters["insecure"], "0")
        XCTAssertEqual(requests(for: url).map(\.route), ["system", "system"])
        XCTAssertEqual(requests(for: url).map { $0.request.value(forHTTPHeaderField: "User-Agent") }, ["Shadowrocket", "ClashMeta"])
    }

    func testFormatNegotiationReusesSuccessfulDirectRouteAndOriginalURL() async throws {
        let (fetcher, url) = makeFetcher(system: "403", format: "mixed-hysteria", timeout: 12)
        let result = try await fetcher.fetchResult(from: url)

        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertTrue(result.skippedSchemes.isEmpty)
        let attempts = requests(for: url)
        XCTAssertEqual(attempts.map(\.route), ["system", "direct", "direct"])
        XCTAssertEqual(attempts.map { $0.request.value(forHTTPHeaderField: "User-Agent") }, ["Shadowrocket", "Shadowrocket", "ClashMeta"])
        for attempt in attempts {
            XCTAssertEqual(attempt.request.url, url)
            XCTAssertEqual(attempt.request.timeoutInterval, 12)
        }
    }

    func testHysteriaOnlyFeedAutomaticallyRequestsClashFormat() async throws {
        let (fetcher, url) = makeFetcher(format: "all-hysteria")
        let result = try await fetcher.fetchResult(from: url)

        XCTAssertEqual(result.nodes.map(\.type.rawValue), ["hysteria2"])
        XCTAssertTrue(result.skippedSchemes.isEmpty)
        XCTAssertEqual(requests(for: url).count, 2)
    }

    func testIncompleteOrDifferentClashFeedKeepsOriginalNodesAndSkipCounts() async throws {
        for alternative in ["incomplete", "drops-original", "renames-original", "changes-credentials", "legacy"] {
            let (fetcher, url) = makeFetcher(format: "mixed-hysteria", alternative: alternative)
            let result = try await fetcher.fetchResult(from: url)

            XCTAssertEqual(result.nodes.map(\.name), ["Example"], alternative)
            XCTAssertEqual(result.skippedSchemes, ["hysteria2": 1], alternative)
            XCTAssertEqual(requests(for: url).count, 2, "格式协商只请求一次")
        }
    }

    func testUnavailableClashFormatKeepsSuccessfullyFetchedNodes() async throws {
        for outcome in ["500", "timeout"] {
            let (fetcher, url) = makeFetcher(format: "mixed-hysteria", clash: outcome)
            let result = try await fetcher.fetchResult(from: url)

            XCTAssertEqual(result.nodes.map(\.name), ["Example"])
            XCTAssertEqual(result.skippedSchemes, ["hysteria2": 1])
            XCTAssertEqual(requests(for: url).count, 2)
        }
    }

    func testCancellationDuringFormatNegotiationIsNotReportedAsPartialSuccess() async throws {
        let (fetcher, url) = makeFetcher(format: "mixed-hysteria", clash: "cancelled")
        do {
            _ = try await fetcher.fetchResult(from: url)
            XCTFail("取消格式协商时不应返回部分成功")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertEqual(requests(for: url).count, 2)
    }

    func testUnsupportedTypesWithoutClashSupportDoNotTriggerFormatNegotiation() async throws {
        let (fetcher, url) = makeFetcher(format: "mixed-tuic")
        let result = try await fetcher.fetchResult(from: url)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.skippedSchemes, ["tuic": 1])
        XCTAssertEqual(requests(for: url).map(\.route), ["system"])
    }

    func testOtherHTTPFailuresDoNotRetryDirect() async throws {
        for status in [401, 404, 429, 500] {
            let (fetcher, url) = makeFetcher(system: String(status))
            do {
                _ = try await fetcher.fetchResult(from: url)
                XCTFail("HTTP \(status) 应保留错误")
            } catch {
                XCTAssertEqual(error as? SubscriptionFetchError, .invalidHTTPStatus(status))
            }
            XCTAssertEqual(requests(for: url).map(\.route), ["system"])
        }
    }

    func testFailedDirectResponseStopsAfterOneRetry() async throws {
        for status in [401, 403, 500] {
            let (fetcher, url) = makeFetcher(system: "403", direct: String(status))
            do {
                _ = try await fetcher.fetchResult(from: url)
                XCTFail("直连失败时不应继续重试")
            } catch {
                XCTAssertEqual(error as? SubscriptionFetchError, .invalidHTTPStatus(status))
            }
            XCTAssertEqual(requests(for: url).map(\.route), ["system", "direct"])
        }
    }

    func testTransportErrorsIncludingCancellationDoNotRetryDirect() async throws {
        for (outcome, code) in [("cancelled", URLError.cancelled), ("timeout", URLError.timedOut)] {
            let (fetcher, url) = makeFetcher(system: outcome)
            do {
                _ = try await fetcher.fetchResult(from: url)
                XCTFail("网络错误应原样返回")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, code)
            }
            XCTAssertEqual(requests(for: url).map(\.route), ["system"])
        }
    }

    func testDirectTransportFailureDoesNotStartAnotherRequest() async throws {
        let (fetcher, url) = makeFetcher(system: "403", direct: "timeout")
        do {
            _ = try await fetcher.fetchResult(from: url)
            XCTFail("直连超时应返回错误")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(requests(for: url).map(\.route), ["system", "direct"])
    }

    func testCancelledTaskDoesNotStartSubscriptionRequest() async throws {
        let (fetcher, url) = makeFetcher(system: "403")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fetcher.fetchResult(from: url)
        }
        do {
            _ = try await task.value
            XCTFail("已取消的操作不应拉取订阅")
        } catch is CancellationError {
            XCTAssertTrue(requests(for: url).isEmpty)
        }
    }

    private func requests(for url: URL) -> [SubscriptionRequestRecorder.Attempt] {
        SubscriptionResponseProtocol.recorder.requests(for: url)
    }

    private func makeFetcher(system: String = "200", direct: String = "200", format: String = "base64",
                             timeout: TimeInterval = 30, clash: String = "200", alternative: String = "complete") -> (SubscriptionFetcher, URL) {
        var components = URLComponents(string: "https://subscription-fetch.invalid/\(format)")!
        components.queryItems = [
            URLQueryItem(name: "token", value: "test-token"),
            URLQueryItem(name: "id", value: UUID().uuidString),
            URLQueryItem(name: "system", value: system),
            URLQueryItem(name: "direct", value: direct),
            URLQueryItem(name: "clash", value: clash),
            URLQueryItem(name: "alternative", value: alternative),
        ]
        let url = components.url!
        let systemConfiguration = URLSessionConfiguration.ephemeral
        systemConfiguration.protocolClasses = [SubscriptionResponseProtocol.self]
        let directConfiguration = URLSessionConfiguration.ephemeral
        directConfiguration.protocolClasses = [DirectSubscriptionResponseProtocol.self]
        let systemSession = URLSession(configuration: systemConfiguration)
        let directSession = URLSession(configuration: directConfiguration)
        addTeardownBlock {
            systemSession.invalidateAndCancel()
            directSession.invalidateAndCancel()
            SubscriptionResponseProtocol.recorder.remove(url)
        }
        return (SubscriptionFetcher(timeout: timeout, session: systemSession, directSession: directSession), url)
    }
}

/// 使用独立会话模拟两条网络路径，避免依赖系统代理或全局注册 URLProtocol。
private class SubscriptionResponseProtocol: URLProtocol {
    static let recorder = SubscriptionRequestRecorder()
    class var route: String { "system" }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "subscription-fetch.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = type(of: self).route
        Self.recorder.append(request, route: route)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let agent = request.value(forHTTPHeaderField: "User-Agent")
        let outcome = query.first { $0.name == (agent == "ClashMeta" ? "clash" : route) }?.value ?? "200"
        if let code = ["cancelled": URLError.cancelled, "timeout": URLError.timedOut][outcome] {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let status = Int(outcome) ?? 200
        let recognized = agent == "Shadowrocket"
        let hysteria = "hysteria2://pw@h.example:443#Hysteria"
        var links = "socks://proxy.example:1080#Example"
        if request.url?.path == "/all-hysteria" { links = hysteria }
        if request.url?.path == "/mixed-hysteria" { links += "\n" + hysteria }
        if request.url?.path == "/mixed-tuic" { links += "\ntuic://uuid:pw@t.example:443#TUIC" }
        let text: String
        if status != 200 {
            text = " "
        } else if agent == "ClashMeta" {
            let original = "  - {name: Example, type: socks5, server: proxy.example, port: 1080}\n"
            let alternative = query.first { $0.name == "alternative" }?.value ?? "complete"
            var yaml = "proxies:\n" + (request.url?.path == "/all-hysteria" ? "" : original) +
                "  - {name: Hysteria, type: hysteria2, server: h.example, ports: '20000-30000', password: pw, sni: h.example, skip-cert-verify: false, obfs: salamander, obfs-password: sample-obfs}\n"
            switch alternative {
            case "incomplete": yaml = "proxies:\n" + original
            case "drops-original": yaml = yaml.replacingOccurrences(of: "server: proxy.example", with: "server: other.example")
            case "renames-original": yaml = yaml.replacingOccurrences(of: "name: Example", with: "name: Renamed")
            case "changes-credentials": yaml = yaml.replacingOccurrences(of: "port: 1080", with: "port: 1080, username: other")
            case "legacy": yaml = Data(links.utf8).base64EncodedString()
            default: break
            }
            text = yaml
        } else if request.url?.path == "/clash" {
            text = ClashSubscriptionParserTests.subscription
        } else if recognized {
            let header = request.url?.path == "/shadowrocket" ? "STATUS=🚀↑:1GB,↓:2GB,TOT:100GB\n" : ""
            text = Data((header + links).utf8).base64EncodedString()
        } else {
            text = "请先下载安装客户端，通过客户端订阅这个网址。"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class DirectSubscriptionResponseProtocol: SubscriptionResponseProtocol {
    override class var route: String { "direct" }
}

private final class SubscriptionRequestRecorder: @unchecked Sendable {
    struct Attempt {
        let route: String
        let request: URLRequest
    }

    private let lock = NSLock()
    private var attempts: [URL: [Attempt]] = [:]

    func append(_ request: URLRequest, route: String) {
        lock.lock()
        defer { lock.unlock() }
        attempts[request.url!, default: []].append(Attempt(route: route, request: request))
    }

    func requests(for url: URL) -> [Attempt] {
        lock.lock()
        defer { lock.unlock() }
        return attempts[url] ?? []
    }

    func remove(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        attempts[url] = nil
    }
}
