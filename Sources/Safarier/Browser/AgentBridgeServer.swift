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
    private static let bootstrapJS = #"""
    if (!window.__safarierRefs) window.__safarierRefs = Object.create(null);
    window.safarier = {
      visible(el) {
        const style = getComputedStyle(el);
        return !el.hidden && style.display !== 'none' && style.visibility !== 'hidden' && el.getClientRects().length > 0;
      },
      resolve(target) {
        if (!target) throw new Error('Empty target');
        const raw = String(target).trim();
        const cleaned = raw.replace(/^\[(?:ref=)?(e\d+)\]$/, '$1');
        if (/^e\d+$/.test(cleaned)) {
          const el = window.__safarierRefs[cleaned];
          if (!el || !el.isConnected) throw new Error('Stale element reference; take a new snapshot: ' + cleaned);
          return el;
        }
        const el = document.querySelector(raw);
        if (!el) throw new Error('Element not found: ' + raw);
        return el;
      },
      snapshot() {
        const refs = Object.create(null);
        window.__safarierRefs = refs;
        const selector = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="checkbox"], [role="tab"], [role="menuitem"], [role="option"], [role="combobox"], [contenteditable]:not([contenteditable="false"]), iframe, summary, [onclick]';
        const elements = [], lines = [];
        for (const el of document.querySelectorAll(selector)) {
          const tag = el.tagName.toLowerCase();
          const type = (el.getAttribute('type') || '').toLowerCase();
          if (type === 'hidden' || !this.visible(el)) continue;
          const ref = 'e' + (elements.length + 1);
          refs[ref] = el;
          const secret = type === 'password';
          const label = String(el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') ||
            el.getAttribute('name') || el.getAttribute('title') || '').trim().replace(/\s+/g, ' ').slice(0, 160);
          const r = el.getBoundingClientRect();
          const x = r.x + r.width / 2, y = r.y + r.height / 2;
          const value = secret ? '[redacted]' : ('value' in el ? String(el.value) : (el.isContentEditable ? el.innerText : null));
          const checked = 'checked' in el ? Boolean(el.checked) : (el.hasAttribute('aria-checked') ? el.getAttribute('aria-checked') === 'true' : null);
          const disabled = Boolean(el.disabled || el.getAttribute('aria-disabled') === 'true');
          const inViewport = r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
          elements.push({ ref, tag, type: type || null, label, x, y, width: r.width, height: r.height, value, checked, disabled, inViewport });
          let desc = '[' + ref + '] <' + tag + (type ? ' type="' + type + '"' : '') + '>';
          if (label) desc += ' ' + JSON.stringify(label);
          desc += ' @(' + Math.round(x) + ',' + Math.round(y) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + ')';
          if (value !== null) desc += ' value=' + JSON.stringify(value.slice(0, 160));
          if (checked !== null) desc += ' checked=' + checked;
          if (disabled) desc += ' disabled';
          if (!inViewport) desc += ' offscreen';
          lines.push(desc);
        }
        const title = document.title || '', url = location.href || '';
        const textSummary = (document.body ? document.body.innerText || '' : '').trim().replace(/\s+/g, ' ').slice(0, 1000);
        const header = 'Title: ' + title + '\nURL: ' + url + (textSummary ? '\nText: ' + textSummary : '');
        return { title, url, textSummary, elements, formatted: header + '\nElements:\n' + (lines.join('\n') || '(none)') };
      },
      prepare(target) {
        const el = this.resolve(target);
        el.scrollIntoView({ block: 'center', inline: 'center' });
        if (el.disabled || el.readOnly || el.getAttribute('aria-disabled') === 'true') throw new Error('Element is not editable or enabled');
        if (typeof el.focus === 'function') el.focus();
        return el;
      },
      click(target) {
        const el = this.prepare(target);
        el.click();
        return { clicked: String(target), tag: el.tagName.toLowerCase() };
      },
      setValue(el, value) {
        const w = el.ownerDocument.defaultView;
        const prototype = el instanceof w.HTMLInputElement ? w.HTMLInputElement.prototype :
          el instanceof w.HTMLTextAreaElement ? w.HTMLTextAreaElement.prototype :
          el instanceof w.HTMLSelectElement ? w.HTMLSelectElement.prototype : null;
        if (prototype) {
          Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, value);
        } else if (el.isContentEditable) {
          el.textContent = value;
        } else {
          throw new Error('Target is not an input, textarea, select or editable element');
        }
      },
      input(el, value, data, inputType) {
        const w = el.ownerDocument.defaultView;
        if (!el.dispatchEvent(new w.InputEvent('beforeinput', { bubbles: true, composed: true, cancelable: true, inputType, data }))) return false;
        this.setValue(el, value);
        el.dispatchEvent(new w.InputEvent('input', { bubbles: true, composed: true, inputType, data }));
        return true;
      },
      fill(target, value) {
        const el = this.prepare(target), text = String(value);
        if (!this.input(el, text, text, 'insertText')) throw new Error('Page cancelled beforeinput');
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { filled: String(target), length: text.length };
      },
      async type(target, text, delayMs = 30) {
        this.prepare(target);
        const delay = Number(delayMs);
        if (!Number.isFinite(delay) || delay < 0 || delay > 1000) throw new Error('delayMs must be between 0 and 1000');
        let count = 0;
        for (const key of String(text)) {
          const el = document.activeElement;
          if (!el || el.disabled || el.readOnly) throw new Error('Active element is not editable');
          const options = { key, bubbles: true, cancelable: true, composed: true };
          const down = el.dispatchEvent(new KeyboardEvent('keydown', options));
          const press = down && el.dispatchEvent(new KeyboardEvent('keypress', options));
          if (press) {
            const current = el.isContentEditable ? el.textContent : el.value;
            if (current === undefined) throw new Error('Active element is not editable');
            let next;
            if (el.maxLength === 1) next = key;
            else if (typeof el.selectionStart === 'number') next = current.slice(0, el.selectionStart) + key + current.slice(el.selectionEnd);
            else next = current + key;
            if (el.maxLength > 1) next = next.slice(0, el.maxLength);
            const caret = typeof el.selectionStart === 'number' ? el.selectionStart + key.length : next.length;
            if (this.input(el, next, key, 'insertText')) {
              if (typeof el.setSelectionRange === 'function') {
                try { el.setSelectionRange(caret, caret); } catch (_) {}
              }
              count++;
            }
          }
          el.dispatchEvent(new KeyboardEvent('keyup', options));
          await this.wait(delay);
        }
        return { typed: String(target), characters: count };
      },
      press(key) {
        const active = document.activeElement || document.body;
        for (const type of ['keydown', 'keypress', 'keyup']) active.dispatchEvent(new KeyboardEvent(type, { key: String(key), bubbles: true, cancelable: true }));
        return { pressed: String(key) };
      },
      wait(msOrSelector) {
        if (typeof msOrSelector === 'string') return this.waitFor(msOrSelector);
        return new Promise(resolve => setTimeout(resolve, Math.max(0, Number(msOrSelector) || 0)));
      },
      async waitFor(query, timeoutMs = 10000) {
        const timeout = Number(timeoutMs);
        if (!query || !Number.isFinite(timeout) || timeout < 0 || timeout > 60000) throw new Error('waitFor requires a query and timeout between 0 and 60000 ms');
        const deadline = performance.now() + timeout;
        do {
          let el;
          try { el = this.resolve(query); } catch (_) {}
          if (!el) {
            const needle = String(query).toLocaleLowerCase();
            el = Array.from(document.querySelectorAll('body *')).find(node =>
              this.visible(node) && !['SCRIPT', 'STYLE', 'IFRAME'].includes(node.tagName) &&
              (node.innerText || '').trim().toLocaleLowerCase().includes(needle));
          }
          if (el && this.visible(el)) return { matched: String(query), tag: el.tagName.toLowerCase() };
          if (performance.now() >= deadline) break;
          await this.wait(Math.min(100, Math.max(0, deadline - performance.now())));
        } while (true);
        throw new Error('Timed out waiting for: ' + query);
      },
      text(selector) {
        const el = selector ? this.resolve(selector) : document.body;
        return el ? (el.innerText || el.textContent || el.value || '').trim() : '';
      }
    };
    """#

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
            // Darwin accepts inherit O_NONBLOCK; reads must wait for the client's first bytes.
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(clientFD, &uid, &gid) == 0, uid == geteuid() else {
                close(clientFD)
                continue
            }
            handleClientConnection(clientFD)
        }
    }

    nonisolated private func handleClientConnection(_ clientFD: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= AgentWireIO.maximumMessageBytes else {
                        Self.writeResponse(AgentResponse(ok: false, error: "Agent request exceeds 8 MiB"), to: clientFD)
                        close(clientFD)
                        return
                    }
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
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.writeResponse(response, to: clientFD)
                    close(clientFD)
                }
            }
        }
    }

    nonisolated private static func writeResponse(_ response: AgentResponse, to fd: Int32) {
        guard var bytes = try? JSONEncoder().encode(response) else { return }
        bytes.append(0x0A)
        try? AgentWireIO.writeAll(bytes, to: fd)
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
            case .type, .wait:
                guard let target = request.target, !target.isEmpty else {
                    return AgentResponse(ok: false, error: "Missing target")
                }
                let controller = try resolveController(tab: request.tab)
                let method = request.action == .type ? "type(target, value, delay)" : "waitFor(target, timeout)"
                let summary = try await runInDefaultClient(
                    script: "\(Self.bootstrapJS)\nreturn JSON.stringify(await window.safarier.\(method));",
                    arguments: ["target": target, "value": request.value ?? "", "delay": request.delayMs ?? 30, "timeout": request.timeoutMs ?? 10000],
                    webView: controller.webView
                )
                return AgentResponse(ok: true, evalResultJSON: summary)
            case .clickXY:
                let controller = try resolveController(tab: request.tab)
                try await clickAtViewportPoint(request, in: controller.webView)
                return AgentResponse(ok: true, message: "clicked viewport coordinates")
            case .focus:
                let controller = try resolveController(tab: request.tab)
                controller.window.makeKeyAndOrderFront(nil)
                controller.window.makeFirstResponder(controller.webView)
                NSApp.activate(ignoringOtherApps: true)
                return makeTabsResponse(message: "focused environment")
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

    private func clickAtViewportPoint(_ request: AgentRequest, in webView: WKWebView) async throws {
        let holdMs = request.delayMs ?? 0
        guard holdMs.isFinite, (0...15000).contains(holdMs) else {
            throw NSError(domain: "SafarierAgent", code: 400, userInfo: [NSLocalizedDescriptionKey: "Hold duration must be between 0 and 15000 milliseconds"])
        }
        let zoom = webView.pageZoom
        guard let x = request.x, let y = request.y, x.isFinite, y.isFinite,
              zoom.isFinite, zoom > 0, x >= 0, y >= 0,
              x * zoom < webView.bounds.width, y * zoom < webView.bounds.height,
              let window = webView.window else {
            throw NSError(domain: "SafarierAgent", code: 400, userInfo: [NSLocalizedDescriptionKey: "Coordinates must be inside the visible web viewport"])
        }
        // DOM viewport coordinates are CSS pixels; AppKit uses points after page zoom.
        let point = NSPoint(x: x * zoom + webView.bounds.minX, y: webView.isFlipped ? y * zoom + webView.bounds.minY : webView.bounds.maxY - y * zoom)
        let windowPoint = webView.convert(point, to: nil)
        // Dispatch to the actual content view without activating a background window.
        let recipient = webView.hitTest(webView.convert(point, to: webView.superview)) ?? webView
        for kind: NSEvent.EventType in [.mouseMoved, .leftMouseDown] {
            guard let event = NSEvent.mouseEvent(
                with: kind, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: kind == .mouseMoved ? 0 : 1, pressure: kind == .leftMouseDown ? 1 : 0
            ) else { continue }
            if kind == .mouseMoved {
                recipient.mouseMoved(with: event)
            } else {
                recipient.mouseDown(with: event)
            }
        }
        if holdMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(holdMs * 1_000_000))
        }
        if let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ) {
            recipient.mouseUp(with: upEvent)
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
