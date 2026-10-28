import CryptoKit
import Darwin
import Foundation

/// AI Agent 本地 IPC 动作（对标 citrolabs/ego-lite 的 Space + Code-based / CLI-based 架构）。
public enum AgentCommandAction: String, Codable, Equatable, Sendable {
    case status
    case tabs
    case open
    case snapshot
    case click
    case fill
    case type
    case clickXY
    case wait
    case focus
    case eval
    case screenshot
    case tabNew
    case tabClose
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var action: AgentCommandAction
    public var tab: Int?
    public var url: String?
    public var newTab: Bool?
    public var target: String?
    public var value: String?
    public var script: String?
    public var outputPath: String?
    public var x: Double?
    public var y: Double?
    public var delayMs: Double?
    public var timeoutMs: Double?

    public init(
        action: AgentCommandAction,
        tab: Int? = nil,
        url: String? = nil,
        newTab: Bool? = nil,
        target: String? = nil,
        value: String? = nil,
        script: String? = nil,
        outputPath: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        delayMs: Double? = nil,
        timeoutMs: Double? = nil
    ) {
        self.action = action
        self.tab = tab
        self.url = url
        self.newTab = newTab
        self.target = target
        self.value = value
        self.script = script
        self.outputPath = outputPath
        self.x = x
        self.y = y
        self.delayMs = delayMs
        self.timeoutMs = timeoutMs
    }
}

public struct AgentTabInfo: Codable, Equatable, Sendable {
    public var index: Int
    public var title: String
    public var url: String
    public var isActive: Bool

    public init(index: Int, title: String, url: String, isActive: Bool) {
        self.index = index
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}

public struct AgentElementRef: Codable, Equatable, Sendable {
    public var ref: String
    public var tag: String
    public var type: String?
    public var label: String

    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var value: String?
    public var checked: Bool?
    public var disabled: Bool?
    public var inViewport: Bool?

    public init(ref: String, tag: String, type: String? = nil, label: String,
                x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil,
                value: String? = nil, checked: Bool? = nil, disabled: Bool? = nil, inViewport: Bool? = nil) {
        self.ref = ref
        self.tag = tag
        self.type = type
        self.label = label
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.value = value
        self.checked = checked
        self.disabled = disabled
        self.inViewport = inViewport
    }
}

public struct AgentSnapshotPayload: Codable, Equatable, Sendable {
    public var title: String
    public var url: String
    public var textSummary: String
    public var elements: [AgentElementRef]
    public var formatted: String

    public init(title: String, url: String, textSummary: String, elements: [AgentElementRef], formatted: String) {
        self.title = title
        self.url = url
        self.textSummary = textSummary
        self.elements = elements
        self.formatted = formatted
    }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var profileID: String?
    public var profileName: String?
    public var message: String?
    public var error: String?
    public var tabs: [AgentTabInfo]?
    public var snapshot: AgentSnapshotPayload?
    public var evalResultJSON: String?
    public var screenshotPath: String?

    public init(
        ok: Bool,
        profileID: String? = nil,
        profileName: String? = nil,
        message: String? = nil,
        error: String? = nil,
        tabs: [AgentTabInfo]? = nil,
        snapshot: AgentSnapshotPayload? = nil,
        evalResultJSON: String? = nil,
        screenshotPath: String? = nil
    ) {
        self.ok = ok
        self.profileID = profileID
        self.profileName = profileName
        self.message = message
        self.error = error
        self.tabs = tabs
        self.snapshot = snapshot
        self.evalResultJSON = evalResultJSON
        self.screenshotPath = screenshotPath
    }
}

public enum AgentIPCError: Error, LocalizedError, Equatable {
    case socketPathTooLong(String)
    case socketCreationFailed(Int32)
    case connectionFailed(String, Int32)
    case writeFailed(Int32)
    case readTimeout
    case emptyResponse
    case messageTooLarge
    case invalidResponse(String)
    case remoteError(String)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            return "Socket 路径超过系统限制：\(path)"
        case .socketCreationFailed(let code):
            return "创建 Unix Socket 失败（errno \(code)）"
        case .connectionFailed(let path, let code):
            return "无法连接到环境 Agent Socket（\(path), errno \(code)）"
        case .writeFailed(let code):
            return "向 Agent Socket 发送请求失败（errno \(code)）"
        case .readTimeout:
            return "等待 Agent 响应超时"
        case .messageTooLarge:
            return "Agent 消息超过 8 MiB 限制"
        case .emptyResponse:
            return "Agent 返回了空响应"
        case .invalidResponse(let detail):
            return "无法解析 Agent 响应：\(detail)"
        case .remoteError(let message):
            return message
        }
    }
}

public enum AgentSocketPath {
    /// Darwin `sockaddr_un.sun_path` 上限 104 字节；若工作区位于深层临时目录，自动映射为 `/tmp` 短路径并通过符号链接关联。
    public static func bindablePath(for socketURL: URL) -> String {
        let raw = socketURL.path
        if raw.utf8.count < 100 {
            return raw
        }
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "/tmp/safarier-\(hex).sock"
    }

    public static func fillAddress(_ path: String, into addr: inout sockaddr_un) throws {
        let utf8 = Array(path.utf8CString)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count <= maxLen else {
            throw AgentIPCError.socketPathTooLong(path)
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
    }
}

/// Bounded newline-delimited JSON transport shared by the CLI and Runner.
public enum AgentWireIO {
    public static let maximumMessageBytes = 8 * 1024 * 1024

    public static func writeAll(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumMessageBytes else { throw AgentIPCError.messageTooLarge }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { throw AgentIPCError.writeFailed(errno) }
            }
        }
    }
}

public enum AgentIPCClient {
    /// 发送请求并等待响应。在主线程调用时会自动转动 RunLoop，避免同进程测试死锁。
    public static func send(_ request: AgentRequest, to socketURL: URL, timeout: TimeInterval = 15) throws -> AgentResponse {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Result<AgentResponse, Error>?
            var result: Result<AgentResponse, Error>? {
                get { lock.lock(); defer { lock.unlock() }; return stored }
                set { lock.lock(); defer { lock.unlock() }; stored = newValue }
            }
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try sendBlocking(request, to: socketURL, timeout: timeout)
                box.result = .success(response)
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(timeout + 1)
        if Thread.isMainThread {
            while box.result == nil && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.015))
            }
        } else {
            _ = semaphore.wait(timeout: .now() + timeout + 1)
        }

        guard let result = box.result else {
            throw AgentIPCError.readTimeout
        }
        return try result.get()
    }

    /// 等待指定环境的 Socket 就绪并返回 `status` 响应。
    @discardableResult
    public static func waitUntilReady(socketURL: URL, timeout: TimeInterval = 10) throws -> AgentResponse {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = AgentIPCError.readTimeout
        while Date() < deadline {
            do {
                let response = try send(AgentRequest(action: .status), to: socketURL, timeout: 1.5)
                if response.ok { return response }
            } catch {
                lastError = error
            }
            if Thread.isMainThread {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw lastError
    }

    private static func sendBlocking(_ request: AgentRequest, to socketURL: URL, timeout: TimeInterval) throws -> AgentResponse {
        let connectPath: String = {
            let resolved = socketURL.resolvingSymlinksInPath().path
            if resolved.utf8.count < 100 && FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
            return AgentSocketPath.bindablePath(for: socketURL)
        }()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentIPCError.socketCreationFailed(errno) }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let wholeSeconds = Int(timeout)
        let microseconds = Int32((timeout - Double(wholeSeconds)) * 1_000_000)
        var tv = timeval(tv_sec: wholeSeconds, tv_usec: microseconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        try AgentSocketPath.fillAddress(connectPath, into: &addr)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw AgentIPCError.connectionFailed(socketURL.path, errno)
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try AgentWireIO.writeAll(payload, to: fd)
        shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard responseData.count + count <= AgentWireIO.maximumMessageBytes else { throw AgentIPCError.messageTooLarge }
                responseData.append(buffer, count: count)
                if buffer[0..<count].contains(0x0A) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw AgentIPCError.readTimeout
            }
        }

        if let newline = responseData.firstIndex(of: 0x0A) {
            responseData = responseData.prefix(upTo: newline)
        }
        guard !responseData.isEmpty else {
            throw AgentIPCError.emptyResponse
        }
        do {
            return try JSONDecoder().decode(AgentResponse.self, from: responseData)
        } catch {
            throw AgentIPCError.invalidResponse(String(decoding: responseData, as: UTF8.self))
        }
    }
}

public enum AgentSkillGuide {
    /// Idempotently synchronize only Safarier's guide, preserving other installed skills.
    @discardableResult
    public static func install(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [URL] {
        let data = Data(markdown.utf8)
        let targets = [".claude", ".claude-ifrr", ".agents"].map {
            homeDirectory.appendingPathComponent("\($0)/skills/safarier-browser/SKILL.md")
        }
        for target in targets {
            if (try? Data(contentsOf: target)) == data { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        return targets
    }

    public static let markdown = #"""
    ---
    name: safarier-browser
    description: Control Safarier browser profiles through its local CLI for authorized browsing, form testing, snapshots, screenshots and human-assisted workflows. Use when a task needs Safarier profile storage or proxy isolation.
    ---

    # Safarier browser automation

    Use the installed executable, even when `safarier` is absent from PATH:

    ```sh
    SF=/Applications/Safarier.app/Contents/MacOS/Safarier
    "$SF" agent spaces
    ```

    In interactive shells, `alias safarier='/Applications/Safarier.app/Contents/MacOS/Safarier'` is optional. For a custom installation, use that app's executable path instead. CLI syntax below assumes the `SF` variable above.

    ## Workflow

    1. Choose an existing profile by UUID or exact name. Open it without taking foreground focus:
       ```sh
       "$SF" agent open "Test Space" https://example.com --background
       "$SF" agent snapshot "Test Space"
       ```
    2. Read the snapshot. Each visible interactive element has an `eN` reference, viewport center `@(x,y widthxheight)`, and relevant value/checked/disabled state. Password values are redacted. Offscreen coordinates are marked; scroll and take another snapshot before using them. References last until a new snapshot or document replacement; take a fresh snapshot after navigation or structural changes.
    3. Fill controlled forms or type through segmented inputs:
       ```sh
       "$SF" agent fill "Test Space" e1 user@example.com
       "$SF" agent click "Test Space" e2
       "$SF" agent wait "Test Space" 'input[autocomplete="one-time-code"]'
       "$SF" agent type "Test Space" 'input[autocomplete="one-time-code"]' 123456 --delay-ms 30
       ```
       Use an OTP supplied by the user or an authorized test fixture. `type` follows the active element on each character, including auto-advancing single-character inputs. `fill` uses native value setters and beforeinput/input/change events; `beforeinput` cancellation is honored. Site-specific controls may still need their own interaction flow.
    4. Re-snapshot and verify the result before a consequential action. A successful command means the interaction was dispatched, not that an account was created or a transaction completed.

    ## Batch execution

    ```sh
    "$SF" agent eval "Test Space" '
      safarier.fill("#email", "user@example.com");
      safarier.click("button[type=submit]");
      await safarier.waitFor("#confirmation", 10000);
      return { text: safarier.text("#confirmation"), snapshot: safarier.snapshot() };
    '
    ```

    Scripts run in an isolated WebKit client world; `safarier` does not become a page-global object. This shares the DOM, not page JS variables or framework internals. DOM operations are scoped to the top document; cross-origin frame DOM remains inaccessible. `eval` is asynchronous, returns JSON, and uses the CLI's 15-second response deadline. Keep batches bounded; use `wait` with `--timeout-ms` (maximum 60000) for longer conditions. After a timeout inspect state before retrying: earlier steps may have completed.

    Helpers:

    - `safarier.snapshot()` refreshes refs and returns `{title,url,textSummary,elements,formatted}`.
    - `safarier.click(target)` scrolls, focuses and invokes a DOM click.
    - `safarier.fill(target,value)` fills input, textarea, select or contenteditable.
    - `await safarier.type(target,text,delayMs=30)` types using the current focused field for every character.
    - `await safarier.waitFor(selectorOrText,timeoutMs=10000)` waits for a visible CSS match, current ref or text substring. Prefer precise CSS selectors to ambiguous text.
    - `await safarier.wait(msOrSelector)` sleeps or waits for a selector.
    - `safarier.press(key)` dispatches DOM keyboard events; it does not implement OS shortcuts or browser default editing.
    - `safarier.text([selector])` extracts rendered text.

    Targets accept `e1`, `[e1]`, `[ref=e1]` or CSS selectors. DOM helper events are synthetic. `type` is not OS keyboard input or a human-behavior simulation.

    ## Coordinates, screenshots and human handoff

    ```sh
    "$SF" agent screenshot "Test Space" /tmp/page.png
    "$SF" agent click-xy "Test Space" 240 380 --tab 1
    "$SF" agent click-xy "Test Space" 240 380 --hold-ms 1000 --tab 1
    "$SF" agent focus "Test Space" --tab 1
    ```

    `click-xy <PROFILE> <X> <Y> [--hold-ms MS] [--tab N]` dispatches native AppKit mouse events to the visible web viewport, in CSS viewport pixels from its top-left corner (page zoom is accounted for). Use a fresh snapshot/screenshot; coordinates change after scrolling, zooming, resizing or navigation. It can target ordinary canvas controls and frame surfaces without reading frame DOM. The optional `--hold-ms MS` keeps the left mouse button down for 0–15000 milliseconds before releasing it (default: 0). Use it for ordinary press-and-hold controls; the CLI extends its response timeout by the hold duration. Direct IPC clients pass this duration in `AgentRequest.delayMs` and must allow enough response time. Native dispatch is not a guarantee that a site accepts an action.

    If a CAPTCHA, passkey confirmation, consent prompt or other human-verification step appears, use `focus`, ask the user to complete it, then inspect the result. Do not solve or bypass CAPTCHA challenges, impersonate a human, or promise an undetectable browser. Profile isolation and Skill availability do not grant permission for external actions.

    ## Tabs and installation

    ```sh
    "$SF" agent tab-list "Test Space"
    "$SF" agent tab-new "Test Space" https://example.org
    "$SF" agent tab-close "Test Space" --tab 2
    "$SF" agent install-skill
    "$SF" agent skill
    ```

    Commands accepting `--tab N` use 1-based indices; re-list after closing a tab. Different profiles can run concurrently; serialize dependent commands within a tab. Local sockets are owner-only (directory 0700, socket 0600); processes under the same macOS account can control that profile. Snapshots and screenshots may contain personal information. Avoid embedding secrets in shell history or persisted logs.

    Opening the Safarier manager synchronizes this guide to `.claude/skills`, `.claude-ifrr/skills` and `.agents/skills` under the user's home directory. Restart or reload your agent's skill discovery if needed. Other clients, including Cursor and OpenCode, may require importing the guide through their own supported configuration.

    [safarier:skill] end of guide
    """#
}
