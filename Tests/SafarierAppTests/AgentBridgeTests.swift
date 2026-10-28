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

    private func loadFixture(_ body: String) throws -> WKWebView {
        let view = try XCTUnwrap(session.openControllers.first?.webView)
        view.loadHTMLString("<!doctype html><title>Agent Fixture</title>" + body, baseURL: URL(string: "https://agent.safarier.invalid/"))
        let deadline = Date().addingTimeInterval(8)
        while (view.isLoading || view.title != "Agent Fixture") && Date() < deadline { spin(0.05) }
        XCTAssertEqual(view.title, "Agent Fixture")
        return view
    }

    private func send(_ request: AgentRequest) throws -> AgentResponse {
        let response = try AgentIPCClient.send(request, to: workspace.agentSocketURL(for: profile.id))
        XCTAssertTrue(response.ok, response.error ?? "Agent request failed")
        return response
    }

    private func evaluate(_ script: String) throws -> [String: Any] {
        let response = try send(AgentRequest(action: .eval, script: script))
        let data = try XCTUnwrap(response.evalResultJSON?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testControlledFormNativeSetterEditableAndCancellation() throws {
        _ = try loadFixture("""
        <input id="controlled"><textarea id="area"></textarea><select id="choice"><option>a</option><option>b</option></select>
        <div id="editor" contenteditable="true">Old</div><input id="blocked" value="unchanged">
        <output id="model"></output><output id="events"></output>
        <script>
        const input = document.querySelector('#controlled');
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        let tracked = '';
        Object.defineProperty(input, 'value', {
          get() { return Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').get.call(this); },
          set(v) { tracked = String(v); setter.call(this, v); }
        });
        input.addEventListener('input', () => {
          if (input.value !== tracked) document.querySelector('#model').textContent = input.value;
        });
        for (const type of ['beforeinput','input','change']) input.addEventListener(type, e => {
          document.querySelector('#events').textContent += e.type + ':' + input.value + ';';
        });
        document.querySelector('#blocked').addEventListener('beforeinput', e => e.preventDefault());
        </script>
        """)
        _ = try send(AgentRequest(action: .fill, target: "#controlled", value: "hello@example.com"))
        _ = try send(AgentRequest(action: .fill, target: "#area", value: "Multiline\ntext"))
        _ = try send(AgentRequest(action: .fill, target: "#choice", value: "b"))
        _ = try send(AgentRequest(action: .fill, target: "#editor", value: "Editable text"))
        let result = try evaluate("return {model: safarier.text('#model'), events: safarier.text('#events'), area: document.querySelector('#area').value, choice: document.querySelector('#choice').value, editor: safarier.text('#editor')};")
        XCTAssertEqual(result["model"] as? String, "hello@example.com")
        XCTAssertEqual(result["events"] as? String, "beforeinput:;input:hello@example.com;change:hello@example.com;")
        XCTAssertEqual(result["area"] as? String, "Multiline\ntext")
        XCTAssertEqual(result["choice"] as? String, "b")
        XCTAssertEqual(result["editor"] as? String, "Editable text")
        let cancelled = try AgentIPCClient.send(AgentRequest(action: .fill, target: "#blocked", value: "wrong"), to: workspace.agentSocketURL(for: profile.id))
        XCTAssertFalse(cancelled.ok)
        XCTAssertEqual(try evaluate("return {value: document.querySelector('#blocked').value};")["value"] as? String, "unchanged")
    }

    func testTypeFollowsOTPAutoAdvanceAndReplacesSingleCharacter() throws {
        _ = try loadFixture("""
        <div id="otp"></div><p id="events"></p>
        <script>
        for (let i = 0; i < 6; i++) {
          const input = document.createElement('input');
          input.id = 'otp' + i; input.maxLength = 1; input.value = '0';
          input.addEventListener('input', () => input.nextElementSibling?.focus());
          for (const type of ['keydown', 'keypress', 'input', 'keyup']) input.addEventListener(type, () => {
            document.querySelector('#events').textContent += type + ',';
          });
          document.querySelector('#otp').append(input);
        }
        </script>
        """)
        _ = try send(AgentRequest(action: .type, target: "#otp0", value: "839201", delayMs: 5))
        let result = try evaluate("return {otp: Array.from(document.querySelectorAll('input')).map(el => el.value).join(''), events: safarier.text('#events')};")
        XCTAssertEqual(result["otp"] as? String, "839201")
        XCTAssertEqual(result["events"] as? String, String(repeating: "keydown,keypress,input,keyup,", count: 6))
    }

    func testWaitForSelectorTextReferenceAndTimeout() throws {
        _ = try loadFixture("<button id='go'>Continue</button>")
        _ = try evaluate("setTimeout(() => { const el = document.createElement('p'); el.id = 'ready'; el.textContent = 'Ready to proceed'; document.body.append(el); }, 150); return {};")
        _ = try send(AgentRequest(action: .wait, target: "#ready", timeoutMs: 3000))
        _ = try send(AgentRequest(action: .wait, target: "Ready to proceed", timeoutMs: 100))
        _ = try send(AgentRequest(action: .snapshot))
        _ = try send(AgentRequest(action: .wait, target: "[ref=e1]", timeoutMs: 100))
        let timedOut = try AgentIPCClient.send(AgentRequest(action: .wait, target: "#never", timeoutMs: 100), to: workspace.agentSocketURL(for: profile.id))
        XCTAssertFalse(timedOut.ok)
        _ = try evaluate("document.querySelector('#go').remove(); return {};")
        let stale = try AgentIPCClient.send(AgentRequest(action: .click, target: "e1"), to: workspace.agentSocketURL(for: profile.id))
        XCTAssertFalse(stale.ok)
    }

    func testSnapshotCoordinatesStateAndPasswordRedaction() throws {
        _ = try loadFixture("""
        <input type="password" value="secret-not-for-snapshots">
        <input type="checkbox" checked disabled><div role="tab">Tab</div>
        <iframe title="Embedded content" srcdoc="<button>Frame</button>"></iframe>
        <div contenteditable="true">Edit</div><input type="hidden" value="hidden">
        """)
        let snapshot = try XCTUnwrap(try send(AgentRequest(action: .snapshot)).snapshot)
        XCTAssertEqual(snapshot.elements.count, 5)
        XCTAssertEqual(snapshot.elements.first?.value, "[redacted]")
        XCTAssertFalse(snapshot.formatted.contains("secret-not-for-snapshots"))
        XCTAssertEqual(snapshot.elements[1].checked, true)
        XCTAssertEqual(snapshot.elements[1].disabled, true)
        XCTAssertTrue(snapshot.elements.contains { $0.tag == "iframe" })
        XCTAssertTrue(snapshot.formatted.contains("@("))
        for element in snapshot.elements {
            XCTAssertGreaterThan(try XCTUnwrap(element.width), 0)
            XCTAssertGreaterThan(try XCTUnwrap(element.height), 0)
            XCTAssertNotNil(element.x)
            XCTAssertNotNil(element.y)
        }
    }

    func testNativeCoordinateClickDispatchesTrustedDOMEvent() throws {
        let webView = try loadFixture("""
        <button style="position:absolute;left:80px;top:100px;width:150px;height:50px" id="native">Native</button>
        <output id="result">none</output>
        <script>document.querySelector('#native').addEventListener('click', e => {
          document.querySelector('#result').textContent = String(e.isTrusted);
        });</script>
        """)
        let snapshot = try XCTUnwrap(try send(AgentRequest(action: .snapshot)).snapshot)
        let button = try XCTUnwrap(snapshot.elements.first { $0.tag == "button" })
        _ = try send(AgentRequest(action: .clickXY, x: try XCTUnwrap(button.x), y: try XCTUnwrap(button.y)))
        _ = try send(AgentRequest(action: .wait, target: "true", timeoutMs: 3000))
        XCTAssertEqual(try evaluate("return {trusted: safarier.text('#result')};")["trusted"] as? String, "true")
        webView.pageZoom = 1.5
        defer { webView.pageZoom = 1 }
        spin(0.1)
        _ = try evaluate("document.querySelector('#result').textContent = 'none'; return {};")
        let zoomed = try XCTUnwrap(try send(AgentRequest(action: .snapshot)).snapshot?.elements.first { $0.tag == "button" })
        _ = try send(AgentRequest(action: .clickXY, x: zoomed.x, y: zoomed.y))
        _ = try send(AgentRequest(action: .wait, target: "true", timeoutMs: 3000))
        XCTAssertEqual(try evaluate("return {trusted: safarier.text('#result')};")["trusted"] as? String, "true")
        let invalid = try AgentIPCClient.send(AgentRequest(action: .clickXY, x: -1, y: 20), to: workspace.agentSocketURL(for: profile.id))
        XCTAssertFalse(invalid.ok)
    }

    func testNativeCoordinateClickHoldsThenReleasesMouse() throws {
        _ = try loadFixture("""
        <button id="hold" style="position:absolute;left:80px;top:100px;width:180px;height:60px">Hold control</button>
        <output id="hold-result"></output>
        <script>
        const button = document.querySelector('#hold');
        let pressed = false, sampledWhilePressed = false, downTime = 0, downTrusted = false;
        button.addEventListener('mousedown', event => {
          pressed = true; downTime = event.timeStamp; downTrusted = event.isTrusted;
          setTimeout(() => { sampledWhilePressed = pressed; }, 75);
        });
        button.addEventListener('mouseup', event => {
          pressed = false;
          const result = document.querySelector('#hold-result');
          result.textContent = JSON.stringify({duration: event.timeStamp - downTime, sampledWhilePressed, pressed, downTrusted, upTrusted: event.isTrusted});
          result.dataset.done = 'true';
        });
        </script>
        """)
        let snapshot = try XCTUnwrap(try send(AgentRequest(action: .snapshot)).snapshot)
        let button = try XCTUnwrap(snapshot.elements.first { $0.tag == "button" })
        let start = ProcessInfo.processInfo.systemUptime
        _ = try send(AgentRequest(action: .clickXY, x: button.x, y: button.y, delayMs: 300))
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.28)
        _ = try send(AgentRequest(action: .wait, target: "#hold-result[data-done=true]", timeoutMs: 3000))
        let state = try evaluate("return JSON.parse(safarier.text('#hold-result'));")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(state["duration"] as? Double), 250)
        XCTAssertEqual(state["sampledWhilePressed"] as? Bool, true, "The page timer must run while the button is held")
        XCTAssertEqual(state["pressed"] as? Bool, false, "Mouse must be released before reporting completion")
        XCTAssertEqual(state["downTrusted"] as? Bool, true)
        XCTAssertEqual(state["upTrusted"] as? Bool, true)
        for invalid in [-1.0, 15001.0] {
            let response = try AgentIPCClient.send(AgentRequest(action: .clickXY, x: button.x, y: button.y, delayMs: invalid), to: workspace.agentSocketURL(for: profile.id))
            XCTAssertFalse(response.ok, "Invalid hold duration must be rejected before pressing")
        }
    }

    func testSkillInstallationIsIdempotentAndUsesAllThreeDirectories() throws {
        let home = tempRoot.appendingPathComponent("skill-home")
        let installed = try AgentSkillGuide.install(homeDirectory: home)
        XCTAssertEqual(installed.count, 3)
        for target in installed {
            XCTAssertEqual(try String(contentsOf: target), AgentSkillGuide.markdown)
        }
        let originalDate = try installed[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try AgentSkillGuide.install(homeDirectory: home)
        XCTAssertEqual(try installed[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, originalDate)
        XCTAssertTrue(AgentSkillGuide.markdown.contains("/Applications/Safarier.app/Contents/MacOS/Safarier"))
        XCTAssertTrue(AgentSkillGuide.markdown.contains("agent focus"))
    }


    func testNativeCoordinateClickReachesOpaqueOriginFrame() throws {
        _ = try loadFixture("""
        <iframe sandbox="allow-scripts" style="position:absolute;left:80px;top:100px;width:200px;height:80px;border:0"
          srcdoc="<button style='width:160px;height:60px' onclick='parent.postMessage(String(event.isTrusted), &quot;*&quot;)'>Frame button</button>"></iframe>
        <output id="result">none</output>
        <script>addEventListener('message', e => { document.querySelector('#result').textContent = e.origin + ':' + e.data; });</script>
        """)
        spin(0.2)
        _ = try send(AgentRequest(action: .clickXY, x: 130, y: 130))
        _ = try send(AgentRequest(action: .wait, target: "null:true", timeoutMs: 3000))
        XCTAssertEqual(try evaluate("return {value: safarier.text('#result')};")["value"] as? String, "null:true")
    }

    func testSocketBurstAndLargeBatchResponse() throws {
        _ = try loadFixture("<p>Transport fixture</p>")
        for _ in 0..<50 { _ = try send(AgentRequest(action: .status)) }
        let response = try send(AgentRequest(action: .eval, script: "return 'x'.repeat(256 * 1024);"))
        let data = try XCTUnwrap(response.evalResultJSON?.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: data).count, 256 * 1024)
        let overLimit = AgentRequest(action: .eval, script: String(repeating: " ", count: AgentWireIO.maximumMessageBytes))
        XCTAssertThrowsError(try AgentIPCClient.send(overLimit, to: workspace.agentSocketURL(for: profile.id))) { error in
            XCTAssertEqual(error as? AgentIPCError, .messageTooLarge)
        }
    }

}
