import AppKit
import Darwin
import Foundation
import WebKit
import SafarierCore

/// 每个运行中的 `BrowserSession` 持有的本地 Unix Domain Socket 自动化桥接服务端。
/// 所有页面脚本均在 `WKContentWorld.defaultClient` 隔离世界中执行，不污染网页自身的 `window` 全局对象。
@MainActor
final class AgentBridgeServer {
    unowned let session: BrowserSession
    let socketURL: URL
    private let bindPath: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "safarier.agent.accept", qos: .userInitiated)

    /// 注入到 `WKContentWorld.defaultClient` 的辅助脚本：维护 `window.__safarierRefs` 与 `window.safarier`。
    private static let bootstrapJS = """
    if (!window.__safarierRefs) {
      window.__safarierRefs = Object.create(null);
    }
    window.safarier = {
      resolve(target) {
        if (!target) throw new Error('Empty target');
        const cleaned = String(target).trim().replace(/^\\[|(?:\\])$/g, '');
        if (window.__safarierRefs && window.__safarierRefs[cleaned] && window.__safarierRefs[cleaned].isConnected) {
          return window.__safarierRefs[cleaned];
        }
        const el = document.querySelector(String(target));
        if (!el) throw new Error('Element not found: ' + target);
        return el;
      },
      snapshot() {
        const refs = Object.create(null);
        window.__safarierRefs = refs;
        const selector = 'a[href], button, input, textarea, select, [role="button"], [onclick]';
        const nodes = Array.from(document.querySelectorAll(selector));
        const elements = [];
        const lines = [];
        let index = 0;
        for (const el of nodes) {
          if (el.hidden) continue;
          const tag = el.tagName.toLowerCase();
          const typeAttr = (el.getAttribute('type') || '').toLowerCase();
          if (tag === 'input' && typeAttr === 'hidden') continue;
          const style = window.getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden') continue;
          index += 1;
          const ref = 'e' + index;
          refs[ref] = el;
          const rawLabel = (
            el.innerText ||
            el.getAttribute('aria-label') ||
            el.getAttribute('placeholder') ||
            el.value ||
            el.getAttribute('name') ||
            el.getAttribute('title') ||
            ''
          ).trim().replace(/\\s+/g, ' ').slice(0, 80);
          elements.push({
            ref,
            tag,
            type: typeAttr || null,
            label: rawLabel
          });
          let desc = '[' + ref + '] <' + tag;
          if (typeAttr) desc += ' type="' + typeAttr + '"';
          const placeholder = el.getAttribute('placeholder');
          if (placeholder) desc += ' placeholder="' + placeholder + '"';
          desc += '>';
          if (rawLabel) desc += ' "' + rawLabel + '"';
          lines.push(desc);
        }
        const title = document.title || '';
        const url = location.href || '';
        const textSummary = (document.body ? (document.body.innerText || document.body.textContent || '') : '')
          .trim()
          .replace(/\\s+/g, ' ')
          .slice(0, 1000);
        const header = 'Title: ' + title + '\\nURL: ' + url + (textSummary ? '\\nText: ' + textSummary : '');
        const formatted = lines.length > 0 ? header + '\\nElements:\\n' + lines.join('\\n') : header + '\\nElements: (none)';
        return { title, url, textSummary, elements, formatted };
      },
      click(target) {
        const el = this.resolve(target);
        if (typeof el.scrollIntoView === 'function') {
          el.scrollIntoView({ block: 'center', inline: 'center' });
        }
        if (typeof el.focus === 'function') {
          el.focus();
        }
        el.click();
        return { clicked: String(target), tag: el.tagName.toLowerCase() };
      },
      fill(target, value) {
        const el = this.resolve(target);
        if (typeof el.scrollIntoView === 'function') {
          el.scrollIntoView({ block: 'center', inline: 'center' });
        }
        if (typeof el.focus === 'function') {
          el.focus();
        }
        el.value = String(value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { filled: String(target), value: String(value) };
      },
      press(key) {
        const active = document.activeElement || document.body || document.documentElement;
        for (const type of ['keydown', 'keypress', 'keyup']) {
          active.dispatchEvent(new KeyboardEvent(type, { key: String(key), bubbles: true, cancelable: true }));
        }
        return { pressed: String(key) };
      },
      wait(ms) {
        return new Promise((resolve) => setTimeout(resolve, Math.max(0, Number(ms) || 0)));
      },
      text(selector) {
        if (!selector) {
          return (document.body ? (document.body.innerText || document.body.textContent || '') : '').trim();
        }
        const el = this.resolve(selector);
        return (el.innerText || el.textContent || el.value || '').trim();
      }
    };
    """

    init(session: BrowserSession, socketURL: URL) {
        self.session = session
        self.socketURL = socketURL
        self.bindPath = AgentSocketPath.bindablePath(for: socketURL)
    }

    func start() throws {
        guard listenFD < 0 else { return }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = chmod(directory.path, mode_t(0o700))

        unlink(socketURL.path)
        if bindPath != socketURL.path {
            unlink(bindPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentIPCError.socketCreationFailed(errno) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        do {
            try AgentSocketPath.fillAddress(bindPath, into: &addr)
        } catch {
            close(fd)
            throw error
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw AgentIPCError.socketCreationFailed(code)
        }
        _ = chmod(bindPath, mode_t(0o600))
        if bindPath != socketURL.path {
            try? FileManager.default.createSymbolicLink(atPath: socketURL.path, withDestinationPath: bindPath)
        }

        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(bindPath)
            unlink(socketURL.path)
            throw AgentIPCError.socketCreationFailed(code)
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections(listenFD: fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(socketURL.path)
        if bindPath != socketURL.path {
            unlink(bindPath)
        }
    }

    nonisolated private func acceptPendingConnections(listenFD: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenFD, sockPtr, &len)
                }
            }
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                break
            }
            handleClientConnection(clientFD)
        }
    }

    nonisolated private func handleClientConnection(_ clientFD: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                    if buffer[0..<count].contains(0x0A) { break }
                } else if count == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            if let newline = data.firstIndex(of: 0x0A) {
                data = data.prefix(upTo: newline)
            }

            let request: AgentRequest
            do {
                request = try JSONDecoder().decode(AgentRequest.self, from: data)
            } catch {
                Self.writeResponse(AgentResponse(ok: false, error: "请求格式无效：\(error)"), to: clientFD)
                close(clientFD)
                return
            }

            Task { @MainActor [weak self] in
                let response: AgentResponse
                if let self {
                    response = await self.handle(request)
                } else {
                    response = AgentResponse(ok: false, error: "会话已关闭")
                }
                Self.writeResponse(response, to: clientFD)
                close(clientFD)
            }
        }
    }

    nonisolated private static func writeResponse(_ response: AgentResponse, to fd: Int32) {
        guard var bytes = try? JSONEncoder().encode(response) else { return }
        bytes.append(0x0A)
        _ = bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(fd, base, rawBuffer.count)
        }
    }

    // MARK: - 请求分发

    func handle(_ request: AgentRequest) async -> AgentResponse {
        do {
            switch request.action {
            case .status, .tabs:
                return makeTabsResponse()
            case .open:
                return try await handleOpen(request)
            case .snapshot:
                let controller = try resolveController(tab: request.tab)
                let snapshot = try await captureSnapshot(in: controller.webView)
                return AgentResponse(
                    ok: true,
                    profileID: session.profile.id.uuidString,
                    profileName: session.profile.name,
                    tabs: collectTabInfos(),
                    snapshot: snapshot
                )
            case .click:
                guard let target = request.target, !target.isEmpty else {
                    return AgentResponse(ok: false, error: "click 缺少目标选择器或引用号（如 e1）")
                }
                let controller = try resolveController(tab: request.tab)
                let summary = try await runInDefaultClient(
                    script: "\(Self.bootstrapJS)\nreturn JSON.stringify(window.safarier.click(target));",
                    arguments: ["target": target],
                    webView: controller.webView
                )
                return AgentResponse(
                    ok: true,
                    profileID: session.profile.id.uuidString,
                    profileName: session.profile.name,
                    message: "clicked \(target)",
                    evalResultJSON: summary
                )
            case .fill:
                guard let target = request.target, !target.isEmpty else {
                    return AgentResponse(ok: false, error: "fill 缺少目标选择器或引用号（如 e1）")
                }
                let value = request.value ?? ""
                let controller = try resolveController(tab: request.tab)
                let summary = try await runInDefaultClient(
                    script: "\(Self.bootstrapJS)\nreturn JSON.stringify(window.safarier.fill(target, value));",
                    arguments: ["target": target, "value": value],
                    webView: controller.webView
                )
                return AgentResponse(
                    ok: true,
                    profileID: session.profile.id.uuidString,
                    profileName: session.profile.name,
                    message: "filled \(target)",
                    evalResultJSON: summary
                )
            case .eval:
                guard let script = request.script, !script.isEmpty else {
                    return AgentResponse(ok: false, error: "eval 缺少 JavaScript 代码")
                }
                let controller = try resolveController(tab: request.tab)
                let wrapped = """
                \(Self.bootstrapJS)
                const safarier = window.safarier;
                const __result = await (async () => {
                \(script)
                })();
                return JSON.stringify(__result === undefined ? null : __result);
                """
                let jsonString = try await runInDefaultClient(script: wrapped, arguments: [:], webView: controller.webView)
                return AgentResponse(
                    ok: true,
                    profileID: session.profile.id.uuidString,
                    profileName: session.profile.name,
                    evalResultJSON: jsonString
                )
            case .screenshot:
                guard let outputPath = request.outputPath, !outputPath.isEmpty else {
                    return AgentResponse(ok: false, error: "screenshot 缺少输出路径")
                }
                let controller = try resolveController(tab: request.tab)
                try await takePNGScreenshot(of: controller.webView, to: URL(fileURLWithPath: outputPath))
                return AgentResponse(
                    ok: true,
                    profileID: session.profile.id.uuidString,
                    profileName: session.profile.name,
                    message: "saved screenshot to \(outputPath)",
                    screenshotPath: outputPath
                )
            case .tabNew:
                let url = try request.url.flatMap(Self.parseURL)
                let host = session.frontmostController ?? session.openControllers.last
                let created = session.openTab(in: host, url: url, background: true)
                if url != nil {
                    await waitUntilLoaded(created.webView)
                }
                return makeTabsResponse(message: "opened tab \(session.openControllers.count)")
            case .tabClose:
                let controller = try resolveController(tab: request.tab)
                controller.window.close()
                return makeTabsResponse(message: "closed tab")
            }
        } catch {
            return AgentResponse(
                ok: false,
                profileID: session.profile.id.uuidString,
                profileName: session.profile.name,
                error: error.localizedDescription
            )
        }
    }

    private func makeTabsResponse(message: String? = nil) -> AgentResponse {
        AgentResponse(
            ok: true,
            profileID: session.profile.id.uuidString,
            profileName: session.profile.name,
            message: message,
            tabs: collectTabInfos()
        )
    }

    private func collectTabInfos() -> [AgentTabInfo] {
        let active = session.frontmostController
        return session.openControllers.enumerated().map { idx, controller in
            let title = controller.webView.title?.isEmpty == false ? controller.webView.title! : controller.window.title
            let url = controller.displayURL?.absoluteString ?? controller.webView.url?.absoluteString ?? "about:blank"
            return AgentTabInfo(index: idx + 1, title: title, url: url, isActive: controller === active)
        }
    }

    private func resolveController(tab: Int?) throws -> BrowserWindowController {
        if session.openControllers.isEmpty {
            _ = session.openWindow(url: nil, background: true)
        }
        if let tab {
            let zeroBased = tab - 1
            guard session.openControllers.indices.contains(zeroBased) else {
                throw NSError(domain: "SafarierAgent", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到标签页 #\(tab)（当前共 \(session.openControllers.count) 个标签页）"])
            }
            return session.openControllers[zeroBased]
        }
        if let frontmost = session.frontmostController {
            return frontmost
        }
        guard let last = session.openControllers.last else {
            throw NSError(domain: "SafarierAgent", code: 404, userInfo: [NSLocalizedDescriptionKey: "当前环境没有打开的标签页"])
        }
        return last
    }

    private func handleOpen(_ request: AgentRequest) async throws -> AgentResponse {
        let parsedURL = try request.url.flatMap(Self.parseURL)
        let targetController: BrowserWindowController
        if request.newTab == true || session.openControllers.isEmpty {
            targetController = session.openTab(in: session.frontmostController, url: parsedURL, background: true)
        } else {
            targetController = try resolveController(tab: request.tab)
            if let parsedURL {
                targetController.load(parsedURL)
            }
        }
        if parsedURL != nil {
            await waitUntilLoaded(targetController.webView)
        }
        return makeTabsResponse(message: parsedURL.map { "opened \($0.absoluteString)" } ?? "ready")
    }

    private static func parseURL(_ raw: String) throws -> URL {
        if let webURL = AddressInput.webURL(for: raw) {
            return webURL
        }
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        throw NSError(domain: "SafarierAgent", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的 URL：\(raw)"])
    }

    private func waitUntilLoaded(_ webView: WKWebView, timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 50_000_000)
        while webView.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func captureSnapshot(in webView: WKWebView) async throws -> AgentSnapshotPayload {
        let jsonString = try await runInDefaultClient(
            script: "\(Self.bootstrapJS)\nreturn JSON.stringify(window.safarier.snapshot());",
            arguments: [:],
            webView: webView
        )
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "SafarierAgent", code: 500, userInfo: [NSLocalizedDescriptionKey: "无法解码 snapshot JSON"])
        }
        return try JSONDecoder().decode(AgentSnapshotPayload.self, from: data)
    }

    private func runInDefaultClient(script: String, arguments: [String: Any], webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    if let string = value as? String {
                        continuation.resume(returning: string)
                    } else if JSONSerialization.isValidJSONObject(value),
                              let data = try? JSONSerialization.data(withJSONObject: value),
                              let encoded = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: encoded)
                    } else {
                        continuation.resume(returning: String(describing: value))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func takePNGScreenshot(of webView: WKWebView, to destinationURL: URL) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: NSError(domain: "SafarierAgent", code: 500, userInfo: [NSLocalizedDescriptionKey: "截图返回为空"]))
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SafarierAgent", code: 500, userInfo: [NSLocalizedDescriptionKey: "生成 PNG 图像数据失败"])
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destinationURL, options: .atomic)
    }
}
