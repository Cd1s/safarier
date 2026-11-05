// Baseline diagnostic for unmodified WebKit, NOT the Safarier extension path.
// swiftc scripts/probe-webrtc-routing.swift -o /tmp/rtc-routing-probe
// /tmp/rtc-routing-probe socks5   (or http)
// Uses only loopback listeners. Exit 0 means the bypass was reproduced, NOT fixed.
import AppKit
import WebKit
import Network

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let udp = try NWListener(using: .udp, on: .any)
let proxy = try NWListener(using: .tcp, on: .any)
var udpReady = false
var proxyReady = false
var stunPackets = 0
var proxyConnections = 0
var connections: [NWConnection] = []
func spin(_ seconds: Double, until condition: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}
udp.stateUpdateHandler = { if case .ready = $0 { udpReady = true } }
proxy.stateUpdateHandler = { if case .ready = $0 { proxyReady = true } }
udp.newConnectionHandler = { connection in
    connections.append(connection)
    connection.start(queue: .main)
    func receive() {
        connection.receiveMessage { data, _, _, error in
            if let data, data.count >= 20, Array(data[4..<8]) == [0x21, 0x12, 0xa4, 0x42] { stunPackets += 1 }
            if error == nil { receive() }
        }
    }
    receive()
}
proxy.newConnectionHandler = { connection in
    proxyConnections += 1
    connections.append(connection)
    connection.start(queue: .main)
}
udp.start(queue: .main)
proxy.start(queue: .main)
spin(3) { udpReady && proxyReady }
guard let udpPort = udp.port, let proxyPort = proxy.port else { fatalError("listeners not ready") }
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: proxyPort)
let kind = CommandLine.arguments.dropFirst().first ?? "socks5"
guard ["socks5", "http"].contains(kind) else { fputs("expected socks5 or http\n", stderr); exit(64) }
configuration.websiteDataStore.proxyConfigurations = [kind == "http" ? ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil) : ProxyConfiguration(socksv5Proxy: endpoint)]
let webView = WKWebView(frame: .zero, configuration: configuration)
webView.loadHTMLString("<!doctype html><title>local WebRTC probe</title>", baseURL: URL(string: "https://rtc.example.invalid/"))
spin(5) { webView.url != nil && !webView.isLoading }
var scriptDone = false
var scriptError = false
webView.evaluateJavaScript("""
window.probeError = null;
window.pc = new RTCPeerConnection({iceServers: [{urls: 'stun:127.0.0.1:\(udpPort.rawValue)'}]});
window.pc.createDataChannel('probe');
window.pc.createOffer().then(o => window.pc.setLocalDescription(o)).catch(e => window.probeError = String(e));
'ready'
""") { result, error in
    print("rtc_api=\(result ?? "nil") script_error=\(error != nil)")
    scriptError = error != nil
    scriptDone = true
}
spin(8) { scriptDone && (stunPackets > 0 || scriptError) }
print("proxy_kind=\(kind) configured_proxies=\(configuration.websiteDataStore.proxyConfigurations.count) direct_stun_packets=\(stunPackets) rtc_proxy_connections=\(proxyConnections)")
let reproducedBypass = scriptDone && !scriptError && stunPackets > 0 && proxyConnections == 0
var closed = false
webView.evaluateJavaScript("window.pc && window.pc.close(); window.probeError") { value, error in
    print("rtc_offer_error=\(value ?? "none")")
    closed = true
}
spin(2) { closed }
let before = proxyConnections
webView.load(URLRequest(url: URL(string: "https://proxy-check.invalid/")!))
spin(5) { proxyConnections > before }
print("https_proxy_connections=\(proxyConnections - before)")
webView.stopLoading()
connections.forEach { $0.cancel() }
udp.cancel()
proxy.cancel()
spin(0.1)

exit(reproducedBypass && proxyConnections > before ? 0 : 1)
