import XCTest
import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

@MainActor
final class AgentBridgeTests: XCTestCase {
    private var tempRoot: URL!
    private var workspace: SafarierWorkspace!
    private var session: BrowserSession!
    private var profile: Profile!

    override func setUp() async throws {
        _ = NSApplication.shared
        tempRoot = URL(fileURLWithPath: "/tmp/safarier-agent-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        workspace = SafarierWorkspace(root: tempRoot)
        profile = Profile(name: "AI-Space", mode: .ephemeral)
        try workspace.profiles.insert(profile)

        let choice = SafarierWebKitInfo.userAgentSafariVersion(
            loadedWebKit: "20621.3.11.11.3",
            installedSafari: "27.0",
            safariStagedWebKit: "20625.1.29.18.28"
        )
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), userAgentVersion: choice)
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        session = BrowserSession(
            profile: profile,
            output: output,
            outboundDescription: "直连",
            diagnostics: SPIDiagnostics(),
            workspace: workspace
        )
        session.start(url: nil, background: true)
    }

    override func tearDown() async throws {
        session?.stopAgentBridge()
        for controller in session?.openControllers ?? [] {
            controller.window.close()
        }
        session = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRunnerLaunchSpecBackgroundFlagRoundTrip() throws {
        let id = UUID()
        let spec = RunnerLaunchSpec(profileID: id, startURL: URL(string: "https://example.com"), background: true)
        XCTAssertTrue(spec.arguments().contains("--background"))
        let parsed = try RunnerLaunchSpec.parse(spec.arguments())
        XCTAssertEqual(parsed, spec)
        XCTAssertTrue(parsed.background)
    }

    func testSkillGuideContainsEndMarker() {
        XCTAssertTrue(AgentSkillGuide.markdown.contains("[safarier:skill] end of guide"))
        XCTAssertTrue(AgentSkillGuide.markdown.contains("safarier.snapshot()"))
    }

    func testSnapshotFillClickEvalScreenshotAndTabsInIsolatedWorld() throws {
        let socketURL = workspace.agentSocketURL(for: profile.id)
        let status = try AgentIPCClient.waitUntilReady(socketURL: socketURL, timeout: 5)
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.profileName, "AI-Space")

        let controller = try XCTUnwrap(session.openControllers.first)
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>Agent Test Page</title></head>
        <body>
          <h1 id="heading">Welcome</h1>
          <input id="email" type="email" placeholder="Email" value="">
          <button id="submit" onclick="document.getElementById('status').textContent = 'Submitted: ' + document.getElementById('email').value">Sign in</button>
          <p id="status">Idle</p>
        </body>
        </html>
        """
        controller.webView.loadHTMLString(html, baseURL: URL(string: "https://agent.safarier.invalid/"))
        let deadline = Date().addingTimeInterval(8)
        while (controller.webView.isLoading || controller.webView.title != "Agent Test Page") && Date() < deadline {
            spin(0.05)
        }

        // 1. snapshot: returns e1 (input) and e2 (button)
        let snapResponse = try AgentIPCClient.send(AgentRequest(action: .snapshot), to: socketURL)
        XCTAssertTrue(snapResponse.ok)
        let snapshot = try XCTUnwrap(snapResponse.snapshot)
        XCTAssertEqual(snapshot.title, "Agent Test Page")
        XCTAssertEqual(snapshot.elements.count, 2)
        XCTAssertEqual(snapshot.elements[0].ref, "e1")
        XCTAssertEqual(snapshot.elements[0].tag, "input")
        XCTAssertEqual(snapshot.elements[1].ref, "e2")
        XCTAssertEqual(snapshot.elements[1].tag, "button")
        XCTAssertTrue(snapshot.formatted.contains("[e1] <input"))
        XCTAssertTrue(snapshot.formatted.contains("[e2] <button> \"Sign in\""))

        // 2. fill e1 + click e2 via CLI/IPC primitives
        let fillResponse = try AgentIPCClient.send(
            AgentRequest(action: .fill, target: "e1", value: "alice@example.com"),
            to: socketURL
        )
        XCTAssertTrue(fillResponse.ok)

        let clickResponse = try AgentIPCClient.send(
            AgentRequest(action: .click, target: "e2"),
            to: socketURL
        )
        XCTAssertTrue(clickResponse.ok)

        // 3. eval: code-based multi-step execution in .defaultClient
        let evalScript = """
        const before = safarier.text('#status');
        safarier.fill('e1', 'bob@example.com');
        safarier.click('e2');
        await safarier.wait(20);
        const after = safarier.text('#status');
        return { before, after };
        """
        let evalResponse = try AgentIPCClient.send(
            AgentRequest(action: .eval, script: evalScript),
            to: socketURL
        )
        XCTAssertTrue(evalResponse.ok)
        let evalJSON = try XCTUnwrap(evalResponse.evalResultJSON?.data(using: .utf8))
        let evalDict = try XCTUnwrap(JSONSerialization.jsonObject(with: evalJSON) as? [String: String])
        XCTAssertEqual(evalDict["before"], "Submitted: alice@example.com")
        XCTAssertEqual(evalDict["after"], "Submitted: bob@example.com")

        // 4. Verify page's own JavaScript world (.page) is NOT polluted by __safarierRefs or window.safarier
        var pageRefsType: String?
        let checkExp = expectation(description: "page world isolation check")
        controller.webView.evaluateJavaScript("typeof window.__safarierRefs + ':' + typeof window.safarier") { value, _ in
            pageRefsType = value as? String
            checkExp.fulfill()
        }
        wait(for: [checkExp], timeout: 5)
        XCTAssertEqual(pageRefsType, "undefined:undefined", ".defaultClient 隔离世界不得污染页面自身的 window 对象")

        // 5. screenshot: writes a valid PNG file even in background mode
        let pngURL = tempRoot.appendingPathComponent("shot.png")
        let shotResponse = try AgentIPCClient.send(
            AgentRequest(action: .screenshot, outputPath: pngURL.path),
            to: socketURL
        )
        XCTAssertTrue(shotResponse.ok)
        let pngData = try Data(contentsOf: pngURL)
        XCTAssertGreaterThan(pngData.count, 100)
        XCTAssertEqual(Array(pngData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG magic header")

        // 6. tabNew / tabs / tabClose
        let tabNewResponse = try AgentIPCClient.send(AgentRequest(action: .tabNew), to: socketURL)
        XCTAssertTrue(tabNewResponse.ok)
        XCTAssertEqual(tabNewResponse.tabs?.count, 2)

        let tabCloseResponse = try AgentIPCClient.send(AgentRequest(action: .tabClose, tab: 2), to: socketURL)
        XCTAssertTrue(tabCloseResponse.ok)
        XCTAssertEqual(tabCloseResponse.tabs?.count, 1)
    }
}
