import XCTest
import SafarierCore
import SafarierNetwork
@testable import Safarier

@MainActor
final class NodeLatencyTests: XCTestCase {
    private var root: URL!
    private var workspace: SafarierWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = SafarierWorkspace(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func subscription(count: Int = 1) throws -> Subscription {
        let nodes = (0..<count).map { SubscriptionNode(name: "Node \($0)", type: .anytls,
            server: "proxy.example.com", serverPort: 443, password: "sample") }
        let subscription = Subscription(name: "Example", url: URL(string: "https://example.com/sub")!, nodes: nodes)
        try workspace.subscriptions.insert(subscription)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("subscriptions.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        return subscription
    }

    private func finish(_ model: ManagerModel, _ subscription: Subscription) async throws {
        let deadline = Date().addingTimeInterval(3)
        while model.isTestingNodes(subscriptionID: subscription.id), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isTestingNodes(subscriptionID: subscription.id))
    }

    func testWholeBatchStartsConcurrentlyAndDeduplicatesRequests() async throws {
        let subscription = try subscription(count: 226)
        let recorder = Recorder()
        let gate = Gate()
        let result = ProxyConnectionResult(exitIP: "203.0.113.1", duration: 0.125)
        let model = ManagerModel(workspace: workspace, nodeTester: { node in
            await recorder.begin(node.id)
            await gate.hold()
            await recorder.end()
            return result
        })
        model.testNodes(subscription.nodes, subscriptionID: subscription.id)
        model.testNodes(subscription.nodes, subscriptionID: subscription.id)
        XCTAssertEqual(model.nodeTests.values.filter { $0 == .running }.count, 226)
        XCTAssertEqual(model.nodeTests.values.filter { $0 == .queued }.count, 0)
        await waitForCalls(226, gate: gate)
        await gate.releaseAll()
        try await finish(model, subscription)
        let (calls, maximum) = await recorder.summary()
        XCTAssertEqual(calls.count, 226)
        XCTAssertEqual(Set(calls).count, 226)
        XCTAssertEqual(maximum, 226)
        for node in subscription.nodes {
            XCTAssertEqual(model.nodeTestState(subscriptionID: subscription.id, node: node), .success(result))
        }
        XCTAssertEqual(try workspace.subscriptions.record(id: subscription.id), subscription)
    }

    func testPickerStartsTheWholeFilteredListInOneBatch() async throws {
        let subscription = try subscription(count: 228)
        let started = expectation(description: "All filtered nodes dispatched together")
        let selected = SubscriptionNodeTableRow.makeRows(subscription.nodes, query: "Node 2") { _ in nil }
            .sorted(using: SubscriptionLatencyComparator())
        let model = ManagerModel(workspace: workspace, nodeBatchTester: { nodes, update in
            XCTAssertEqual(nodes.map(\.id), selected.map(\.id))
            XCTAssertEqual(nodes.count, 39)
            started.fulfill()
            for node in nodes {
                await update(node.id, .success(ProxyConnectionResult(exitIP: "203.0.113.1", duration: 0.1)))
            }
        })
        model.testNodes(selected.map(\.node), subscriptionID: subscription.id)
        await fulfillment(of: [started], timeout: 2)
        try await finish(model, subscription)
        XCTAssertEqual(model.nodeTests.count, selected.count)
        for node in subscription.nodes where !selected.contains(where: { $0.id == node.id }) {
            XCTAssertNil(model.nodeTestState(subscriptionID: subscription.id, node: node))
        }
    }

    func testCancelClearsQueueAndIgnoresLateSuccessThenAllowsRetry() async throws {
        let subscription = try subscription(count: 5)
        let started = expectation(description: "started")
        started.expectedFulfillmentCount = 5
        let model = ManagerModel(workspace: workspace, nodeTester: { _ in
            started.fulfill()
            try? await Task.sleep(for: .milliseconds(150))
            return ProxyConnectionResult(exitIP: "203.0.113.2", duration: 0.15)
        })
        model.testNodes(subscription.nodes, subscriptionID: subscription.id)
        await fulfillment(of: [started], timeout: 2)
        model.cancelNodeTests(subscriptionID: subscription.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.nodeTests.isEmpty)
        let retry = ManagerModel(workspace: workspace, nodeTester: { _ in throw ProxyConnectionError.timeout })
        retry.testNodes(subscription.nodes, subscriptionID: subscription.id)
        try await finish(retry, subscription)
        XCTAssertTrue(retry.nodeTests.values.allSatisfy { $0 == .failure(ProxyConnectionError.timeout.localizedDescription) })
    }

    func testRefreshAndExternalChangesDiscardOldResults() async throws {
        var subscription = try subscription()
        let result = ProxyConnectionResult(exitIP: "203.0.113.3", duration: 0.2)
        let model = ManagerModel(workspace: workspace, nodeTester: { _ in
            try await Task.sleep(for: .milliseconds(50))
            return result
        })
        model.testNodes(subscription.nodes, subscriptionID: subscription.id)
        subscription.nodes[0].password = "updated"
        try workspace.subscriptions.update(subscription)
        try await finish(model, subscription)
        XCTAssertTrue(model.nodeTests.isEmpty)
        model.reload()
        model.testNodes(subscription.nodes, subscriptionID: subscription.id)
        try await finish(model, subscription)
        XCTAssertEqual(model.nodeTests.count, 1)
        try workspace.subscriptions.delete(id: subscription.id)
        model.reload()
        XCTAssertTrue(model.nodeTests.isEmpty)
        model.testNodes(subscription.nodes, subscriptionID: subscription.id)
        XCTAssertTrue(model.nodeTests.isEmpty)
    }

    func testExecutorCancellationDoesNotLeaveRunningState() async throws {
        let subscription = try subscription(count: 5)
        let model = ManagerModel(workspace: workspace, nodeTester: { _ in throw CancellationError() })
        model.testNodes(subscription.nodes, subscriptionID: subscription.id)
        try await finish(model, subscription)
        XCTAssertTrue(model.nodeTests.isEmpty)
    }

    func testCancelAndImmediateRetryWaitForOldWorkersToCleanUp() async throws {
        let subscription = try subscription(count: 3)
        let gate = Gate()
        let result = ProxyConnectionResult(exitIP: "203.0.113.4", duration: 0.25)
        let model = ManagerModel(workspace: workspace, nodeTester: { _ in
            await gate.hold()
            return result
        })
        model.testNodes(subscription.nodes, subscriptionID: subscription.id)
        await waitForCalls(3, gate: gate)
        model.cancelNodeTests(subscriptionID: subscription.id)
        model.testNodes([subscription.nodes[0]], subscriptionID: subscription.id)
        XCTAssertEqual(model.nodeTestState(subscriptionID: subscription.id, node: subscription.nodes[0]), .queued)
        let callsBeforeCleanup = await gate.calls
        XCTAssertEqual(callsBeforeCleanup, 3)
        await gate.releaseAll()
        await waitForCalls(4, gate: gate)
        await gate.releaseAll()
        try await finish(model, subscription)
        XCTAssertEqual(model.nodeTests.count, 1)
        XCTAssertEqual(model.nodeTestState(subscriptionID: subscription.id, node: subscription.nodes[0]), .success(result))
    }

    private func waitForCalls(_ count: Int, gate: Gate) async {
        let deadline = Date().addingTimeInterval(2)
        while await gate.calls < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let calls = await gate.calls
        XCTAssertEqual(calls, count)
    }

    private actor Gate {
        var calls = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        func hold() async {
            calls += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        func releaseAll() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor Recorder {
        var active = 0
        var maximum = 0
        var calls: [UUID] = []
        func begin(_ id: UUID) { active += 1; maximum = max(maximum, active); calls.append(id) }
        func end() { active -= 1 }
        func summary() -> ([UUID], Int) { (calls, maximum) }
    }
}
