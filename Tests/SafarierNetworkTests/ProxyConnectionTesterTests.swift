import XCTest
import SafarierCore
@testable import SafarierNetwork

@MainActor
final class ProxyConnectionTesterTests: XCTestCase {
    func testBothProtocolsUseAuthenticatedTunnelDespiteNoProxyEnvironment() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        let previous = ProcessInfo.processInfo.environment["NO_PROXY"]
        setenv("NO_PROXY", "*", 1)
        defer { if let previous { setenv("NO_PROXY", previous, 1) } else { unsetenv("NO_PROXY") } }
        for kind in ProxyKind.allCases {
            let result = try await fixture.check(kind, password: "test-secret")
            XCTAssertEqual(result.exitIP, "203.0.113.7")
            XCTAssertGreaterThan(result.duration, 0)
        }
        let requests = try String(contentsOf: fixture.root.appendingPathComponent("proxy-requests"), encoding: .utf8)
        XCTAssertTrue(requests.contains("http authenticated"))
        XCTAssertTrue(requests.contains("socks authenticated"))
    }

    func testAuthenticationFailureDoesNotReachTargetOrFallBackDirect() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        for kind in ProxyKind.allCases {
            do {
                _ = try await fixture.check(kind, password: "wrong")
                XCTFail("错误密码不能测试成功")
            } catch let error as ProxyConnectionError {
                switch (kind, error) {
                case (.httpConnect, .authentication), (.socks5, .handshake): break
                default: XCTFail("错误分类不正确：\(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("target-requests").path))
    }

    func testRejectsUntrustedCertificateAndInvalidExitIP() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        do {
            _ = try await fixture.check(.httpConnect, trusted: false)
            XCTFail("不能绕过证书校验")
        } catch let error as ProxyConnectionError {
            guard case .tls = error else { return XCTFail("预期 TLS 错误：\(error)") }
        }
        do {
            _ = try await fixture.check(.socks5, path: "invalid")
            XCTFail("无效 IP 不能显示为成功")
        } catch let error as ProxyConnectionError {
            guard case .invalidResponse = error else { return XCTFail("预期响应错误：\(error)") }
        }
    }

    func testTargetErrorTimeoutAndCancellation() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        do {
            _ = try await fixture.check(.httpConnect, path: "status")
            XCTFail("HTTP 503 不能显示成功")
        } catch let error as ProxyConnectionError {
            guard case .http(503) = error else { return XCTFail("预期 HTTP 错误：\(error)") }
        }
        do {
            _ = try await fixture.check(.socks5, path: "stall", timeout: 0.2)
            XCTFail("应当超时")
        } catch let error as ProxyConnectionError {
            guard case .timeout = error else { return XCTFail("预期超时：\(error)") }
        }
        let task = Task { try await fixture.check(.httpConnect, path: "stall") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后不能返回成功")
        } catch is CancellationError { XCTAssertTrue(task.isCancelled) }
    }

    func testTwoHopChainsAuthenticateAndStopWhenEitherHopFails() async throws {
        guard SingboxProcessManager.locateExecutable() != nil else { throw XCTSkip("本机没有 sing-box") }
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        let previous = ProcessInfo.processInfo.environment["NO_PROXY"]
        setenv("NO_PROXY", "*", 1)
        defer { if let previous { setenv("NO_PROXY", previous, 1) } else { unsetenv("NO_PROXY") } }
        for entry in ProxyKind.allCases {
            for exit in ProxyKind.allCases {
                let result = try await fixture.checkChain(entry: entry, exit: exit)
                XCTAssertEqual(result.exitIP, "203.0.113.7")
            }
        }
        let entries = try String(contentsOf: fixture.root.appendingPathComponent("entry-requests"), encoding: .utf8)
        XCTAssertTrue(entries.contains("http exit.invalid"))
        XCTAssertTrue(entries.contains("socks exit.invalid"))
        let targetBefore = try Data(contentsOf: fixture.root.appendingPathComponent("target-requests"))
        for offline in ["entry-offline", "exit-offline"] {
            let marker = fixture.root.appendingPathComponent(offline)
            try Data().write(to: marker)
            do {
                _ = try await fixture.checkChain(entry: .socks5, exit: .httpConnect)
                XCTFail("任一跳失败都不能绕过链路")
            } catch { }
            try FileManager.default.removeItem(at: marker)
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("target-requests")), targetBefore)
        }
        do {
            _ = try await fixture.checkChain(entry: .socks5, exit: .httpConnect, path: "stall", timeout: 0.2)
            XCTFail("链路测试应当超时")
        } catch let error as ProxyConnectionError {
            guard case .timeout = error else { return XCTFail("预期超时：\(error)") }
        }
        let task = Task { try await fixture.checkChain(entry: .socks5, exit: .httpConnect, path: "stall") }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消链路测试后不能成功")
        } catch is CancellationError { XCTAssertTrue(task.isCancelled) }
    }
}

/// 只连接本机：临时 CA、HTTPS 目标及 HTTP/SOCKS5 认证代理，不修改系统证书或使用公网服务。
@MainActor
final class HTTPSProxyFixture {
    let root: URL
    let process = Process()
    let ports: [String: Int]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let script = root.appendingPathComponent("fixture.py")
            try Self.script.write(to: script, atomically: true, encoding: .utf8)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, root.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let ready = root.appendingPathComponent("ports.json")
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: ready))
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func check(_ kind: ProxyKind, password: String = "test-secret", path: String = "trace", trusted: Bool = true, timeout: TimeInterval = 5) async throws -> ProxyConnectionResult {
        let port = try XCTUnwrap(ports[kind == .socks5 ? "socks" : "http"])
        let targetPort = try XCTUnwrap(ports["https"])
        let proxy = ProxySettings(name: "Fixture", kind: kind, host: "127.0.0.1", port: port, username: "test-user")
        return try await ProxyConnectionTester.check(
            proxy: proxy, password: password, target: URL(string: "https://localhost:\(targetPort)/\(path)")!,
            certificate: trusted ? root.appendingPathComponent("cert.pem") : nil, timeout: timeout
        )
    }

    func checkChain(entry entryKind: ProxyKind, exit exitKind: ProxyKind, path: String = "trace", timeout: TimeInterval = 5) async throws -> ProxyConnectionResult {
        let workspace = SafarierWorkspace(root: root.appendingPathComponent("workspace"))
        let credentials = InMemoryCredentialStore()
        let entry = ProxySettings(name: "Entry", kind: entryKind, host: "127.0.0.1", port: try XCTUnwrap(ports[entryKind == .socks5 ? "entry-socks" : "entry-http"]), username: "test-user")
        try workspace.proxies.insert(entry)
        let exit = ProxySettings(name: "Exit", kind: exitKind, host: "exit.invalid", port: try XCTUnwrap(ports[exitKind == .socks5 ? "socks" : "http"]), username: "test-user", upstream: .proxy(entry.id))
        try credentials.setPassword("test-secret", forKey: entry.credentialKey)
        try credentials.setPassword("test-secret", forKey: exit.credentialKey)
        let chain = try XCTUnwrap(ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials))
        let target = URL(string: "https://localhost:\(try XCTUnwrap(ports["https"]))/\(path)")!
        let certificate = root.appendingPathComponent("cert.pem")
        return try await ProxyConnectionTester.check(chain: chain) { local, password in
            try await ProxyConnectionTester.check(proxy: local, password: password, target: target, certificate: certificate, timeout: timeout)
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }

    private static let script = #"""
import base64,http.server,json,pathlib,select,signal,socket,socketserver,ssl,subprocess,sys,threading,time
root=pathlib.Path(sys.argv[1])
(root/'cert.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\n')
subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',str(root/'key.pem'),'-out',str(root/'cert.pem'),'-config',str(root/'cert.cnf')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=8)
def record(file,text):
    with (root/file).open('a') as f:f.write(text+'\n')
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        record('target-requests',self.path)
        if self.path=='/stall':time.sleep(4)
        body=b'ip=invalid\n' if self.path=='/invalid' else b'ip=203.0.113.7\n'
        self.send_response(503 if self.path=='/status' else 200)
        self.send_header('Content-Length',str(len(body)));self.end_headers()
        try:self.wfile.write(body)
        except OSError:pass
    def log_message(self,*args):pass
page=http.server.ThreadingHTTPServer(('127.0.0.1',0),Page)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(root/'cert.pem',root/'key.pem')
page.socket=context.wrap_socket(page.socket,server_side=True)
threading.Thread(target=page.serve_forever,daemon=True).start()
def readn(s,n):
    data=b''
    while len(data)<n:
        part=s.recv(n-len(data))
        if not part:raise EOFError()
        data+=part
    return data
class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        if (root/'exit-offline').exists():return
        s=self.request;s.settimeout(6)
        try:
            if self.server.kind=='http':
                head=b''
                while not head.endswith(b'\r\n\r\n'):head+=readn(s,1)
                expected=b'proxy-authorization: basic '+base64.b64encode(b'test-user:test-secret')
                if expected.lower() not in head.lower():
                    s.sendall(b'HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');return
                assert head.startswith(('CONNECT localhost:'+str(page.server_port)+' ').encode())
                s.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            else:
                version,count=readn(s,2);methods=readn(s,count);assert version==5 and 2 in methods
                s.sendall(b'\x05\x02');version,n=readn(s,2);user=readn(s,n);password=readn(s,readn(s,1)[0])
                if user!=b'test-user' or password!=b'test-secret':s.sendall(b'\x01\x01');return
                s.sendall(b'\x01\x00');version,command,_,typ=readn(s,4);assert command==1 and typ==3
                host=readn(s,readn(s,1)[0]);port=int.from_bytes(readn(s,2),'big');assert host==b'localhost' and port==page.server_port
                s.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
            record('proxy-requests',self.server.kind+' authenticated')
            with socket.create_connection(('127.0.0.1',page.server_port)) as upstream:
                while True:
                    ready,_,_=select.select([s,upstream],[],[],6)
                    if not ready:return
                    for source in ready:
                        data=source.recv(65536)
                        if not data:return
                        (upstream if source is s else s).sendall(data)
        except (OSError,EOFError):pass
class Server(socketserver.ThreadingTCPServer):daemon_threads=True
ports={'https':page.server_port}
for kind in ['http','socks']:
    server=Server(('127.0.0.1',0),Proxy);server.kind=kind;ports[kind]=server.server_address[1]
    threading.Thread(target=server.serve_forever,daemon=True).start()
class Entry(socketserver.BaseRequestHandler):
    def handle(self):
        if (root/'entry-offline').exists():return
        s=self.request;s.settimeout(6)
        try:
            if self.server.kind=='http':
                head=b''
                while not head.endswith(b'\r\n\r\n'):head+=readn(s,1)
                expected=b'proxy-authorization: basic '+base64.b64encode(b'test-user:test-secret')
                assert expected.lower() in head.lower()
                command,destination,_=head.split(b'\r\n',1)[0].split(b' ')
                assert command==b'CONNECT'
                host,port=destination.rsplit(b':',1);port=int(port)
            else:
                version,count=readn(s,2);methods=readn(s,count);assert version==5 and 2 in methods
                s.sendall(b'\x05\x02');version,n=readn(s,2);user=readn(s,n);password=readn(s,readn(s,1)[0])
                assert user==b'test-user' and password==b'test-secret'
                s.sendall(b'\x01\x00');version,command,_,typ=readn(s,4);assert command==1 and typ==3
                host=readn(s,readn(s,1)[0]);port=int.from_bytes(readn(s,2),'big')
            # 此域名只在前置代理中识别，本机 DNS 无法解析。
            assert host==b'exit.invalid' and port in [ports['http'],ports['socks']]
            record('entry-requests',self.server.kind+' '+host.decode())
            with socket.create_connection(('127.0.0.1',port)) as upstream:
                s.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n' if self.server.kind=='http' else b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
                while True:
                    ready,_,_=select.select([s,upstream],[],[],6)
                    if not ready:return
                    for source in ready:
                        data=source.recv(65536)
                        if not data:return
                        (upstream if source is s else s).sendall(data)
        except (OSError,EOFError,AssertionError):pass
for kind in ['http','socks']:
    server=Server(('127.0.0.1',0),Entry);server.kind=kind;ports['entry-'+kind]=server.server_address[1]
    threading.Thread(target=server.serve_forever,daemon=True).start()
(root/'ports.tmp').write_text(json.dumps(ports));(root/'ports.tmp').rename(root/'ports.json')
signal.pause()
"""#
}
