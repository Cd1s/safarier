import XCTest
import SafarierCore
import SafarierNetwork
@testable import Safarier

final class SubscriptionNodeSortTests: XCTestCase {
    private func rows(_ states: [ManagerModel.ProxyTestState?]) -> [SubscriptionNodeTableRow] {
        states.enumerated().map { index, state in
            SubscriptionNodeTableRow(node: SubscriptionNode(name: "Node \(index)", type: .socks,
                                                            server: "proxy.example.com", serverPort: 1080),
                                     testState: state, sourceOrder: index)
        }
    }

    private func success(_ duration: TimeInterval) -> ManagerModel.ProxyTestState {
        .success(ProxyConnectionResult(exitIP: "203.0.113.1", duration: duration))
    }

    func testBothDirectionsKeepFailuresLastAndPendingNodesInSourceOrder() {
        let rows = rows([.failure("timeout"), success(0.8), nil, success(0.1),
                         .running, .failure("handshake"), .queued])
        XCTAssertEqual(rows.sorted(using: SubscriptionLatencyComparator()).map(\.sourceOrder),
                       [3, 1, 2, 4, 6, 0, 5])
        XCTAssertEqual(rows.sorted(using: SubscriptionLatencyComparator(order: .reverse)).map(\.sourceOrder),
                       [1, 3, 2, 4, 6, 0, 5])
    }

    func testEqualDurationsAndUntestedRowsKeepSubscriptionOrder() {
        for states: [ManagerModel.ProxyTestState?] in [
            [nil, nil, nil], [success(0.1), success(0.1), success(0.1)],
            [.failure("a"), .failure("b"), .failure("c")]
        ] {
            let rows = rows(states)
            for order in [SortOrder.forward, .reverse] {
                XCTAssertEqual(rows.reversed().sorted(using: SubscriptionLatencyComparator(order: order)).map(\.id),
                               rows.map(\.id))
            }
        }
    }

    func testNewSuccessAndFailureImmediatelyChangeDisplayOrder() {
        var rows = rows([nil, success(0.3), .failure("timeout")])
        let comparator = SubscriptionLatencyComparator()
        XCTAssertEqual(rows.sorted(using: comparator).map(\.sourceOrder), [1, 0, 2])
        rows[0].testState = success(0.1)
        XCTAssertEqual(rows.sorted(using: comparator).map(\.sourceOrder), [0, 1, 2])
        rows[0].testState = .failure("offline")
        XCTAssertEqual(rows.sorted(using: comparator).map(\.sourceOrder), [1, 0, 2])
    }
}
