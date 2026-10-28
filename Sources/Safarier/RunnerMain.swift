import AppKit
import WebKit
import SafarierCore
import SafarierNetwork
import SafarierWebKit

/// Runner 进程入口：一个进程只服务一个 profile。
@MainActor
enum RunnerMain {
    /// 进程存活期间一直持有，退出（含崩溃）时内核自动释放。
    private static var lock: ProfileLock?
    private static var controller: AnyObject?
    private static var signalSources: [DispatchSourceSignal] = []
    /// 绑定订阅节点时由这个 Runner 拉起的 sing-box。atexit 和信号处理里要用，所以不隔离到主线程。
    nonisolated(unsafe) private static var singbox: (manager: SingboxProcessManager, profileID: UUID)?

    static func start(arguments: [String]) -> Never {
        // Manager 把 stdout 重定向到日志文件；改成行缓冲，否则进程被结束时最后的输出会丢。
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let spec = try RunnerLaunchSpec.parse(arguments, environment: ProcessInfo.processInfo.environment)
            let workspace = try SafarierWorkspace.default()
            guard let profile = try workspace.profiles.record(id: spec.profileID) else {
                fail("找不到 profile \(spec.profileID.uuidString)")
            }
            lock = try ProfileLock.acquire(profileID: profile.id, in: workspace.locksDirectory)
            installTerminationCleanup()
            let diagnostics = SPIDiagnostics.standardError()

            // 屏幕能力是进程级的，要赶在 WebKit 第一次收集屏幕属性（第一个 WKWebView 创建）之前装好。
            let displayState = profile.deviceModel.flatMap(MacDeviceModel.preset)
                .map { DeviceSimulation.installDisplayOverride(for: $0, diagnostics: diagnostics) }

            // 出站：独立代理直接交给 WebKit；订阅节点先起 sing-box，把它的本地 SOCKS5 入站当成代理交给 WebKit。
            // 后者在工厂看来就是"绑定了一个代理"，所以 sing-box 断了时页面加载失败，不会退回直连。
            var effectiveProfile = profile
            var proxy = try profile.proxyID.flatMap { try workspace.proxies.record(id: $0) }
            var outbound: [String: Any] = proxy.map { ["kind": "proxy", "name": $0.name] } ?? ["kind": "direct"]
            var outboundDescription = proxy.map { "代理「\($0.name)」（\($0.kind.rawValue) \($0.host):\($0.port)）" } ?? "直连"

            let bound = try workspace.boundNode(for: profile)
            if let bound {
                let local = try startSingbox(profileID: profile.id, node: bound.node, workspace: workspace)
                effectiveProfile.proxyID = local.proxy.id
                proxy = local.proxy
                outbound = [
                    "kind": "subscriptionNode",
                    "subscription": bound.subscription.name,
                    "node": bound.node.name,
                    "protocol": bound.node.type.rawValue,
                    "singboxPID": local.pid,
                    "localProxy": "\(local.proxy.host):\(local.proxy.port)",
                ]
                outboundDescription = "订阅「\(bound.subscription.name)」节点「\(bound.node.name)」（经 sing-box）"
            }

            // 原生引擎接口只在 profile（或本次 --spi）显式开启时才碰；公开适配器先写结论，SPI 适配器再覆盖。
            var spiFeatures = spec.spiOverride ?? profile.spi

            // 语言 / 时区跟随代理：按出口 IP 的国家定下语言和时区，再交给工厂。
            if profile.followProxyLanguages || profile.followProxyTimeZone {
                // 重新启动过的 Runner 带着上一次的结果：先记下是不是重启过，用完就把这些环境变量清掉，不再传给子进程。
                let wasRelaunched = ProcessInfo.processInfo.environment[ProxyGeoResult.relaunchFlag] != nil
                let resolved = resolveFollowProxy(proxy: proxy, nodeHint: bound?.node.name)
                for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("SAFARIER_GEO_") { unsetenv(key) }
                if let resolved {
                    outbound["geo"] = [
                        "country": resolved.countryCode, "languages": resolved.languages,
                        "timeZone": resolved.timeZoneIdentifier, "source": "\(resolved.source)",
                    ]
                    if profile.followProxyLanguages {
                        // -AppleLanguages 只能在进程启动时生效：语言不一样就带上新参数重新启动自己（只重启一次）。
                        let current = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
                        if current != resolved.languages && !wasRelaunched {
                            relaunch(arguments: arguments, resolved: resolved, followTimeZone: profile.followProxyTimeZone)
                        }
                        effectiveProfile.languages = resolved.languages
                    }
                    if profile.followProxyTimeZone {
                        effectiveProfile.timeZoneIdentifier = resolved.timeZoneIdentifier
                        spiFeatures.insert(.engineTimeZone)
                    }
                } else {
                    FileHandle.standardError.write(Data("[geo] 跟随代理没能确定出口国家，语言和时区沿用系统\n".utf8))
                }
            }
            let privacy = CompositePrivacyAdapter([
                PublicAPIPrivacyAdapter(),
                SPIPrivacyAdapter(features: spiFeatures, diagnostics: diagnostics),
            ])
            let factory = WebViewConfigurationFactory(credentials: KeychainCredentialStore(), privacy: privacy, extensionWorkspace: workspace)
            var output = try factory.make(profile: effectiveProfile, proxy: proxy)
            if let displayState { output.report.set(displayState, for: .displayCapabilities) }

            let app = NSApplication.shared
            if spec.probe {
                app.setActivationPolicy(.prohibited)
                let probe = ProbeController(
                    profile: effectiveProfile,
                    spec: spec,
                    output: output,
                    adapter: factory.privacy.identifier,
                    spiFeatures: spiFeatures,
                    diagnostics: diagnostics,
                    outbound: outbound
                )
                controller = probe
                probe.start()
            } else {
                app.setActivationPolicy(.regular)
                app.mainMenu = BrowserMenu.make()
                let session = BrowserSession(profile: effectiveProfile, output: output, outboundDescription: outboundDescription, diagnostics: diagnostics, workspace: workspace)
                controller = session
                app.delegate = session
                session.start(url: spec.startURL, background: spec.background)
            }
            app.run()
            exit(0)
        } catch {
            fail("Runner 启动失败：\(error)")
        }
    }

    /// 跟随代理：重新启动过的 Runner 直接用带过来的结果；否则经代理探测出口国家（失败时按节点名推断）。
    private static func resolveFollowProxy(proxy: ProxySettings?, nodeHint: String?) -> ProxyGeoResult? {
        let environment = ProcessInfo.processInfo.environment
        if let carried = ProxyGeoResult(relaunchedFrom: environment) { return carried }
        let password = proxy.flatMap { proxy -> String? in
            guard proxy.username?.isEmpty == false else { return nil }
            return try? KeychainCredentialStore().password(forKey: proxy.credentialKey)
        }
        let resolved = ProxyGeoResolver.resolve(proxy: proxy, password: password, nodeHint: nodeHint)
        if let resolved {
            FileHandle.standardError.write(Data("[geo] 出口 \(resolved.countryCode)：语言 \(resolved.languages)，时区 \(resolved.timeZoneIdentifier)（\(resolved.source)）\n".utf8))
        }
        return resolved
    }

    /// 带上新的 `-AppleLanguages`（和跟随代理的 TZ）重新执行自己：先停 sing-box、释放 profile 锁，
    /// 进程号不变，管理器的进程跟踪不受影响。重新启动后的进程从头开始，再起 sing-box、再拿锁。
    private static func relaunch(arguments: [String], resolved: ProxyGeoResult, followTimeZone: Bool) -> Never {
        stopSingbox()
        lock?.release()
        lock = nil
        for (key, value) in resolved.relaunchEnvironment { setenv(key, value, 1) }
        if followTimeZone { setenv("TZ", resolved.timeZoneIdentifier, 1) }
        let executable = RunnerLauncher.currentExecutableURL().path
        let argv = [executable] + RunnerLaunchSpec.replacingAppleLanguages(resolved.languages, in: arguments)
        FileHandle.standardError.write(Data("[geo] 带上 -AppleLanguages \(resolved.languages) 重新启动 Runner\n".utf8))
        var cArguments = argv.map { strdup($0) } + [nil]
        execv(executable, &cArguments)
        fail("重新启动 Runner 失败（errno \(errno)）")
    }

    /// 起 sing-box 并等它的本地端口可用。stdout/stderr 进 Runner 自己的日志（级别 warn，不记访问的域名）。
    private static func startSingbox(
        profileID: UUID,
        node: SubscriptionNode,
        workspace: SafarierWorkspace
    ) throws -> (proxy: ProxySettings, pid: Int32) {
        let manager = SingboxProcessManager(stateDirectory: workspace.singboxDirectory, logHandle: FileHandle.standardError)
        singbox = (manager, profileID)
        let pid = try manager.start(profileID: profileID, node: node)
        let port = try manager.waitUntilReady(profileID: profileID)
        // 写 stderr：探针模式下 stdout 只能有 JSON。
        FileHandle.standardError.write(Data("[sing-box] \(manager.executableURL.path) pid \(pid)，节点「\(node.name)」（\(node.type.rawValue) \(node.server):\(node.serverPort)）→ 127.0.0.1:\(port)\n".utf8))
        let proxy = ProxySettings(name: "sing-box", kind: .socks5, host: SingboxConfigBuilder.defaultInboundAddress, port: port)
        return (proxy, pid)
    }

    /// 结束本 Runner 拉起的 sing-box。会被调用多次（applicationWillTerminate、atexit、信号），只有第一次生效。
    nonisolated static func stopSingbox() {
        guard let (manager, profileID) = singbox else { return }
        singbox = nil
        try? manager.stop(profileID: profileID)
    }

    /// 所有退出路径都要带走 sing-box：exit()（含 NSApp.terminate 和 fail）走 atexit，
    /// SIGTERM/SIGINT/SIGHUP 先清理再按原信号退出（管理器据此区分"被结束"和"出错"）。
    /// SIGKILL 和崩溃拦不住，留下的进程由下次启动或图形管理器按 pid 文件清理。
    private static func installTerminationCleanup() {
        atexit { RunnerMain.stopSingbox() }
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                RunnerMain.stopSingbox()
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
