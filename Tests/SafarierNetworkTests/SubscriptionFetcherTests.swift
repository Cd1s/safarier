import Foundation
import XCTest
@testable import SafarierNetwork

final class SubscriptionFetcherTests: XCTestCase {
    func testFetchSendsClientUserAgentAndParsesSubscription() async throws {
        XCTAssertTrue(URLProtocol.registerClass(SubscriptionUserAgentProtocol.self))
        defer { URLProtocol.unregisterClass(SubscriptionUserAgentProtocol.self) }

        let url = URL(string: "https://subscription-user-agent.invalid/subscribe")!
        let result = try await SubscriptionFetcher().fetchResult(from: url)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.server, "proxy.example")
        XCTAssertEqual(result.nodes.first?.serverPort, 1080)
    }
}

/// 外部订阅服务边界：仅在客户端标识正确时返回 Base64 节点，其余请求返回提示文字。
private final class SubscriptionUserAgentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "subscription-user-agent.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recognized = request.value(forHTTPHeaderField: "User-Agent") == "Shadowrocket"
        let text = recognized
            ? Data("socks://proxy.example:1080#Example".utf8).base64EncodedString()
            : "请先下载安装客户端，通过客户端订阅这个网址。"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
