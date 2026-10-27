import AppKit
import WebKit
import SafarierCore
import SafarierWebKit

/// M0 探针：不显示窗口，加载页面后只读取网页能看到的值（不改写任何东西），
/// 连同能力报告一起以 JSON 打到 stdout 后退出。
/// 退出码：0 成功，2 超时，3 页面加载失败，4 脚本执行失败。
@MainActor
final class ProbeController: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let timeout: TimeInterval = 30
    /// 没给 --url 时加载的本地页面；baseURL 只用来给页面一个正常的 https origin，不会发网络请求。
    private static let blankHTML = "<!doctype html><html><head><meta charset=utf-8><title>Safarier probe</title></head><body></body></html>"
    private static let blankBaseURL = URL(string: "https://probe.safarier.invalid/")!

    /// 主线程和 Worker 各读一遍：进程级设置如果只影响主线程，这里能看出来。
    /// fingerprint 部分只读取 Canvas/WebGL/Audio 的输出并算哈希，用来观察引擎自己的反指纹噪声，不改写任何 API。
    private static let observeScript = """
    const snapshot = () => ({
      userAgent: navigator.userAgent,
      language: navigator.language,
      languages: Array.from(navigator.languages || []),
      timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      locale: Intl.DateTimeFormat().resolvedOptions().locale,
      timezoneOffsetMinutes: new Date().getTimezoneOffset(),
      januaryOffsetMinutes: new Date(2026, 0, 15).getTimezoneOffset(),
      julyOffsetMinutes: new Date(2026, 6, 15).getTimezoneOffset(),
      sampleLocalTime: new Date(Date.UTC(2026, 0, 15, 12)).toString(),
      hardwareConcurrency: navigator.hardwareConcurrency,
      fonts: (() => {
        try {
          const g = typeof document !== 'undefined' ? document.createElement('canvas').getContext('2d') : new OffscreenCanvas(16, 16).getContext('2d');
          const text = 'mmmmmmmmmmlliWW 0123456789 中文字体测试漢字 ทดสอบ';
          const width = (family) => { g.font = '48px ' + family; return String(g.measureText(text).width); };
          const baseMonospace = width('monospace'), baseSerif = width('serif');
          const detected = {};
          for (const name of ['PingFang SC', '苹方-简', '黑体', '微软雅黑', 'Heiti SC', '黑体-简', 'Hiragino Sans GB', 'Songti SC', '宋体', 'Times', 'Courier', 'Thonburi']) {
            detected[name] = width('"' + name + '", monospace') !== baseMonospace || width('"' + name + '", serif') !== baseSerif;
          }
          const generic = {};
          for (const family of ['serif', 'sans-serif', 'monospace', 'system-ui', '-apple-system']) generic[family] = width(family);
          return { detected, generic };
        } catch (error) { return { error: String(error) }; }
      })()
    });
    const fnv = (values) => {
      let h = 0x811c9dc5;
      for (let i = 0; i < values.length; i++) {
        h ^= typeof values === 'string' ? values.charCodeAt(i) : values[i];
        h = Math.imul(h, 0x01000193) >>> 0;
      }
      return h.toString(16).padStart(8, '0');
    };
    const drawCanvas = () => {
      const c = document.createElement('canvas');
      c.width = 240; c.height = 60;
      const g = c.getContext('2d');
      g.textBaseline = 'top'; g.font = '16px "Helvetica Neue", Arial';
      g.fillStyle = '#f60'; g.fillRect(120, 1, 62, 20);
      g.fillStyle = '#069'; g.fillText('Safarier probe 指纹 ✓', 2, 15);
      g.fillStyle = 'rgba(102, 204, 0, 0.7)'; g.fillText('Safarier probe 指纹 ✓', 4, 17);
      const grad = g.createLinearGradient(0, 0, 240, 0);
      grad.addColorStop(0, 'red'); grad.addColorStop(1, 'blue');
      g.fillStyle = grad; g.beginPath(); g.arc(210, 35, 18, 0, Math.PI * 2); g.fill();
      return c;
    };
    const canvasProbe = () => {
      try {
        const a = drawCanvas();
        return {
          dataURL: fnv(a.toDataURL()),
          dataURLRepeat: fnv(a.toDataURL()),
          dataURLFreshCanvas: fnv(drawCanvas().toDataURL()),
          imageData: fnv(a.getContext('2d').getImageData(0, 0, a.width, a.height).data)
        };
      } catch (error) { return { error: String(error) }; }
    };
    const webglProbe = () => {
      try {
        const c = document.createElement('canvas');
        c.width = 64; c.height = 64;
        const gl = c.getContext('webgl', { preserveDrawingBuffer: true });
        if (!gl) return { error: 'no webgl' };
        const shader = (type, source) => { const s = gl.createShader(type); gl.shaderSource(s, source); gl.compileShader(s); return s; };
        const program = gl.createProgram();
        gl.attachShader(program, shader(gl.VERTEX_SHADER, 'attribute vec2 p; attribute vec3 c; varying vec3 v; void main(){ v = c; gl_Position = vec4(p, 0.0, 1.0); }'));
        gl.attachShader(program, shader(gl.FRAGMENT_SHADER, 'precision mediump float; varying vec3 v; void main(){ gl_FragColor = vec4(v, 1.0); }'));
        gl.linkProgram(program); gl.useProgram(program);
        gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-0.9, -0.9, 1, 0, 0, 0.9, -0.8, 0, 1, 0, 0.1, 0.9, 0, 0, 1]), gl.STATIC_DRAW);
        const p = gl.getAttribLocation(program, 'p'), col = gl.getAttribLocation(program, 'c');
        gl.enableVertexAttribArray(p); gl.vertexAttribPointer(p, 2, gl.FLOAT, false, 20, 0);
        gl.enableVertexAttribArray(col); gl.vertexAttribPointer(col, 3, gl.FLOAT, false, 20, 8);
        gl.clearColor(0.1, 0.1, 0.1, 1); gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLES, 0, 3);
        const pixels = new Uint8Array(64 * 64 * 4);
        gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
        const info = gl.getExtension('WEBGL_debug_renderer_info');
        return {
          readPixels: fnv(pixels),
          dataURL: fnv(c.toDataURL()),
          vendor: gl.getParameter(gl.VENDOR),
          renderer: gl.getParameter(gl.RENDERER),
          unmaskedRenderer: info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : null
        };
      } catch (error) { return { error: String(error) }; }
    };
    const audioProbe = async () => {
      try {
        const ctx = new OfflineAudioContext(1, 5000, 44100);
        const osc = ctx.createOscillator();
        osc.type = 'triangle'; osc.frequency.value = 10000;
        const comp = ctx.createDynamicsCompressor();
        comp.threshold.value = -50; comp.knee.value = 40; comp.ratio.value = 12; comp.attack.value = 0; comp.release.value = 0.25;
        osc.connect(comp); comp.connect(ctx.destination); osc.start(0);
        const data = (await ctx.startRendering()).getChannelData(0);
        let sum = 0;
        for (let i = 4500; i < 5000; i++) sum += Math.abs(data[i]);
        return { sum: String(sum), samples: fnv(new Uint8Array(data.buffer)) };
      } catch (error) { return { error: String(error) }; }
    };
    const main = Object.assign(snapshot(), {
      screen: [screen.width, screen.height, window.devicePixelRatio],
      viewport: [window.innerWidth, window.innerHeight],
      outer: [window.outerWidth, window.outerHeight],
      devicePixelRatio: window.devicePixelRatio,
      safariAPIs: { applePay: 'ApplePaySession' in window, push: 'PushManager' in window, mediaDevices: 'mediaDevices' in navigator, safariObject: 'safari' in window, fullscreenEnabled: document.fullscreenEnabled },
      display: { colorGamutP3: matchMedia('(color-gamut: p3)').matches, dynamicRangeHigh: matchMedia('(dynamic-range: high)').matches, videoDynamicRangeHigh: matchMedia('(video-dynamic-range: high)').matches, colorDepth: screen.colorDepth },
      webGPU: { present: 'gpu' in navigator, adapter: await (async () => { try { const a = navigator.gpu && await navigator.gpu.requestAdapter(); return a ? { vendor: a.info && a.info.vendor, architecture: a.info && a.info.architecture } : null; } catch (e) { return String(e); } })() },
      rtcPeerConnectionDefined: typeof RTCPeerConnection !== 'undefined',
      cookieEnabled: navigator.cookieEnabled,
      href: location.href,
      bodyTextSample: (document.body && document.body.innerText || '').slice(0, 1500),
      fingerprint: { canvas: canvasProbe(), webgl: webglProbe(), audio: await audioProbe() }
    });
    let worker;
    try {
      const source = 'const s = ' + snapshot.toString() + '; postMessage(s());';
      const url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
      worker = await new Promise((resolve) => {
        const w = new Worker(url);
        const timer = setTimeout(() => { w.terminate(); resolve({ error: 'timeout' }); }, 5000);
        w.onmessage = (event) => { clearTimeout(timer); w.terminate(); resolve(event.data); };
        w.onerror = (event) => { clearTimeout(timer); resolve({ error: String(event.message || 'worker error') }); };
      });
    } catch (error) {
      worker = { error: String(error) };
    }
    return { main, worker };
    """

    private let profile: Profile
    private let spec: RunnerLaunchSpec
    private var output: WebViewConfigurationFactory.Output
    private let adapter: String
    private let spiFeatures: SPIFeatures
    private let diagnostics: SPIDiagnostics
    private let outbound: [String: Any]
    private let window: NSWindow
    private let webView: WKWebView
    private var finished = false

    init(
        profile: Profile,
        spec: RunnerLaunchSpec,
        output: WebViewConfigurationFactory.Output,
        adapter: String,
        spiFeatures: SPIFeatures,
        diagnostics: SPIDiagnostics,
        outbound: [String: Any]
    ) {
        self.profile = profile
        self.spec = spec
        self.output = output
        self.adapter = adapter
        self.spiFeatures = spiFeatures
        self.diagnostics = diagnostics
        self.outbound = outbound
        // 屏幕外的窗口：WKWebView 不在窗口里时计时器会被节流，Worker 结果可能拿不到。
        // 选了模拟机型时视口用机型的推荐尺寸（屏幕外，不用缩小）。
        let size = profile.deviceModel.flatMap(MacDeviceModel.preset)?.viewportSize ?? CGSize(width: 1280, height: 800)
        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: output.configuration)
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let model = profile.deviceModel.flatMap(MacDeviceModel.preset) {
            self.output.report.set(DeviceSimulation(model: model, diagnostics: diagnostics).apply(to: webView), for: .deviceModel)
        }
    }

    /// 和浏览窗口一样把窗口尺寸交给 WebKit，否则网页读到 outerWidth = 0。
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewGetWindowFrame(_ webView: WKWebView, completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(window.frame)
    }

    func start() {
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.finish(status: 2, observed: nil, error: "超时（\(Int(Self.timeout)) 秒）")
        }
        if let url = spec.startURL {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(Self.blankHTML, baseURL: Self.blankBaseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(Self.observeScript, arguments: [:], in: nil, in: .page) { [weak self] result in
            switch result {
            case .success(let value):
                self?.finish(status: 0, observed: value, error: nil)
            case .failure(let error):
                self?.finish(status: 4, observed: nil, error: "脚本执行失败：\(error)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(status: 3, observed: nil, error: Self.describe(error))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(status: 3, observed: nil, error: Self.describe(error))
    }

    private func finish(status: Int32, observed: Any?, error: String?) {
        guard !finished else { return }
        finished = true

        var document: [String: Any] = [
            "profile": [
                "id": profile.id.uuidString,
                "name": profile.name,
                "mode": profile.mode.rawValue,
                "languages": profile.languages,
                "timeZone": profile.timeZoneIdentifier as Any? ?? NSNull(),
                "followProxyLanguages": profile.followProxyLanguages,
                "followProxyTimeZone": profile.followProxyTimeZone,
                "spi": profile.spi.tokenList,
                "deviceModel": profile.deviceModel as Any? ?? NSNull(),
            ],
            "outbound": outbound,
            "process": [
                "arguments": spec.arguments(),
                "appleLanguages": UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? [],
                "timeZone": TimeZone.current.identifier,
            ],
            "environment": [
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "webKit": SafarierWebKitInfo.systemWebKitVersion as Any? ?? NSNull(),
                "safari": SafarierWebKitInfo.installedSafariVersion as Any? ?? NSNull(),
                "safariStagedWebKit": SafarierWebKitInfo.safariStagedWebKitVersion as Any? ?? NSNull(),
            ],
            "privacyAdapter": adapter,
            "spi": [
                "requested": spiFeatures.tokenList,
                "source": spec.spiOverride == nil ? "profile" : "--spi",
                "diagnostics": diagnostics.entries,
            ],
            "capabilities": Dictionary(uniqueKeysWithValues: PrivacyFeature.allCases.map { feature -> (String, Any) in
                let state = output.report[feature]
                return (feature.rawValue, ["state": state.name, "detail": state.detail as Any? ?? NSNull()])
            }),
            "status": status,
        ]
        if let observed { document["observed"] = observed }
        if let error { document["error"] = error }

        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data("探针结果无法序列化：\(document)\n".utf8))
        }
        exit(status)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }
}
