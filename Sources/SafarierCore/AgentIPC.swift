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

    public init(
        action: AgentCommandAction,
        tab: Int? = nil,
        url: String? = nil,
        newTab: Bool? = nil,
        target: String? = nil,
        value: String? = nil,
        script: String? = nil,
        outputPath: String? = nil
    ) {
        self.action = action
        self.tab = tab
        self.url = url
        self.newTab = newTab
        self.target = target
        self.value = value
        self.script = script
        self.outputPath = outputPath
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

    public init(ref: String, tag: String, type: String? = nil, label: String) {
        self.ref = ref
        self.tag = tag
        self.type = type
        self.label = label
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

public enum AgentIPCClient {
    /// 发送请求并等待响应。在主线程调用时会自动转动 RunLoop，避免同进程测试死锁。
    public static func send(_ request: AgentRequest, to socketURL: URL, timeout: TimeInterval = 15) throws -> AgentResponse {
        final class Box: @unchecked Sendable {
            var result: Result<AgentResponse, Error>?
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
        let written = payload.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(fd, base, rawBuffer.count)
        }
        guard written == payload.count else {
            throw AgentIPCError.writeFailed(errno)
        }
        shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
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
    public static let markdown = """
    ---
    name: safarier-browser
    description: Drive Safarier isolated browser spaces (profiles) from AI agents via the local `safarier agent` CLI bridge without stealing foreground focus or polluting page JavaScript globals.
    ---

    # Safarier Browser Agent Skill (`safarier agent`)

    Safarier provides a native macOS WebKit browser where every Profile ("Space") has an isolated website data store, independent proxy / sing-box outbound tunnel, native Safari anti-fingerprinting protections, and a local Unix Domain Socket bridge for AI agents.

    All DOM queries and code-based interactions run inside `WKContentWorld.defaultClient` (isolated from page scripts) and `--background` launches never steal window focus from the human user.

    ## Quick Start Workflow

    1. **List available spaces (profiles) and running status:**
       ```sh
       safarier agent spaces
       ```

    2. **Open a URL in a space (auto-launches in background if not running):**
       ```sh
       safarier agent open <PROFILE_ID_OR_NAME> https://example.com --background
       ```

    3. **Take a structured DOM snapshot with interactive element refs (`e1`, `e2`, ...):**
       ```sh
       safarier agent snapshot <PROFILE_ID_OR_NAME>
       ```

    4. **Interact using element refs (`e1`) or CSS selectors:**
       ```sh
       safarier agent fill <PROFILE_ID_OR_NAME> e1 "user@example.com"
       safarier agent click <PROFILE_ID_OR_NAME> e2
       ```

    5. **Code-based multi-step execution (`eval`):**
       Batch multiple actions in one round-trip using the built-in `safarier` helper in `.defaultClient`:
       ```sh
       safarier agent eval <PROFILE_ID_OR_NAME> '
         safarier.fill("e1", "hello");
         safarier.click("e2");
         await safarier.wait(200);
         return { title: document.title, text: safarier.text(), snap: safarier.snapshot() };
       '
       ```

    6. **Capture a PNG screenshot (works in background without foregrounding the window):**
       ```sh
       safarier agent screenshot <PROFILE_ID_OR_NAME> /tmp/page.png
       ```

    7. **Manage tabs inside a space:**
       ```sh
       safarier agent tab-list <PROFILE_ID_OR_NAME>
       safarier agent tab-new <PROFILE_ID_OR_NAME> https://example.org
       safarier agent tab-close <PROFILE_ID_OR_NAME> --tab 2
       ```

    ## Built-in `safarier` Helper API in `eval`

    - `safarier.snapshot()` — Returns `{ title, url, textSummary, elements, formatted }` and refreshes `e1`, `e2`, ... refs.
    - `safarier.click(target)` — Scrolls into view, focuses, and clicks `e1` ref or CSS selector.
    - `safarier.fill(target, value)` — Focuses input/textarea/select, sets `.value`, and dispatches `input` + `change` events.
    - `safarier.press(key)` — Dispatches `keydown`/`keypress`/`keyup` events on the active element.
    - `safarier.wait(ms)` — Returns a Promise resolving after `ms` milliseconds.
    - `safarier.text([selector])` — Returns trimmed text of the matching element (or `document.body` when omitted).

    [safarier:skill] end of guide
    """
}
