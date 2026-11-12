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

    func testPickerSearchFiltersNamesAndEndpointsThenKeepsFailuresLastInBothDirections() {
        let original = rows([success(0.8), .failure("timeout"), success(0.05), .running, success(0.1)])
        var nodes = original.map(\.node)
        for index in [0, 1, 3, 4] { nodes[index].name = "Europe \(index)" }
        nodes[2].server = "edge.example.com"
        nodes[2].serverPort = 8443
        let states = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.testState) })
        let filtered = SubscriptionNodeTableRow.makeRows(nodes, query: "  EUROPE\n") { states[$0.id] ?? nil }
        XCTAssertEqual(filtered.sorted(using: SubscriptionLatencyComparator()).map(\.sourceOrder), [4, 0, 3, 1])
        XCTAssertEqual(filtered.sorted(using: SubscriptionLatencyComparator(order: .reverse)).map(\.sourceOrder), [0, 4, 3, 1])
        XCTAssertEqual(SubscriptionNodeTableRow.makeRows(nodes, query: "EDGE.EXAMPLE.COM:8443") { states[$0.id] ?? nil }.map(\.id),
                       [nodes[2].id])
        XCTAssertTrue(SubscriptionNodeTableRow.makeRows(nodes, query: "no-match") { states[$0.id] ?? nil }.isEmpty)
    }

    func testClearingPickerSearchRestoresEveryOriginalNodeAndKeepsSelectionIdentity() {
        let original = rows([success(0.8), .failure("timeout"), success(0.1)])
        let states = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.testState) })
        let nodes = original.map(\.node)
        let filtered = SubscriptionNodeTableRow.makeRows(nodes, query: "Node 1") { states[$0.id] ?? nil }
        XCTAssertEqual(filtered.map(\.node), [nodes[1]])
        let restored = SubscriptionNodeTableRow.makeRows(nodes, query: " \n ") { states[$0.id] ?? nil }
            .sorted(using: SubscriptionLatencyComparator())
        XCTAssertEqual(restored.map(\.id), [nodes[2].id, nodes[0].id, nodes[1].id])
        XCTAssertEqual(restored.last?.node, filtered.first?.node)
    }
}
