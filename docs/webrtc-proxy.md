# WebRTC 独立代理：系统扩展草案

状态：Draft；独立设计审查 CONDITIONAL，D1–D5 已由主 agent 收敛并实现。签名实机验收未完成，不可发布为已修复。

## 问题与目标

2026-11-04 macOS 27.0.1 / WebKit 22625.1.29.11.28 本机探针发现：WKWebsiteDataStore 配置 SOCKS5 或 HTTP CONNECT 后，HTTPS 连接到代理，RTCPeerConnection 的 STUN UDP 仍直接到本地接收器。每种代理均为 1 个直接 STUN 包、0 个 RTC 代理连接、1 个 HTTPS 代理连接。现有 defaultProxiedFeatures 关闭 RTC，并不实现代理。

用户要求保留通话，已授权开发系统扩展并提交 Draft PR；无 provisioning profile，不能做系统激活/媒体验收。本轮不改系统保护、不安装扩展、不发布。当前有效 Developer ID 身份不等于已获得 Network Extension entitlement。

目标是实现可编译、可测的 SOCKS5 UDP ASSOCIATE/TCP 转发和系统扩展接线，保留 RTCPeerConnection。HTTP CONNECT 仅支持 TCP，不假装支持 UDP；对 UDP 拒绝且不直连。HTTP 环境的通话依赖站点 TURN/TCP，不能承诺任意站点可用。订阅/自定义出站仍通过各 Runner 自有 sing-box SOCKS 入站，远端协议是否支持 UDP 另行验收。

## 结构与契约

- 新模块 `SafarierProxyTransport`：Foundation/Network；SOCKS5、RFC1929 身份验证、CONNECT、UDP ASSOCIATE 和 UDP 包编解码，及 HTTP CONNECT TCP。单条 UDP flow 一条 TCP 控制连接和一条连到 relay 的 UDP 连接。拒绝非零 FRAG、无效 RSV/ATYP/长度/端口。保留原目的地址并把回复源地址写回 flow。无直连 fallback。
- `SafarierProxyExtension` 可执行目标：`NETransparentProxyProvider`，bundle `sh.safarier.app.network-extension`。使用公开 NE API，监听所有出站 TCP/UDP（包含 IPv4/IPv6 loopback），只接管已注册 Runner 的完整 audit token。其它应用和未注册进程不改变路由。网络回调串行化，flow/连接有数量上限、握手超时和关闭清理。
- `SafarierProxyControl`：共享 XPC 协议、路由注册 DTO、客户端和纯路由表。系统扩展 Mach service `TEAM.sh.safarier.proxy.control`；TEAM 来自打包时 Info.plist。双方 `NSXPCConnection.setCodeSigningRequirement` 要求 Apple 签名链、同 TEAM、精确 bundle identifier；不信任调用方传入的 profile 名或 PID。
- Runner 用自身 task_info(TASK_AUDIT_TOKEN) 取得 token。服务端以 XPC 的 `processIdentifier`/EUID 校验 token 的 PID/EUID，使用 `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` 验证完整 token 对应的运行进程及签名；注册绑定到该 XPC 连接，不允许替换。注册包含 profile UUID、有效代理配置和内存密码；密码不放命令行、日志、磁盘或 providerConfiguration。
- 路由键是完整 audit token（包含 pidversion），不是 PID、可执行文件路径或 profile 名。flow 只通过 NEFlowMetaData.sourceAppAuditToken 匹配；禁止猜 WebKit PID、按同 bundle 共享代理。已注册 token 的 TCP 连接若目的地址恰为该代理端点则允许原路径，避免 WK 的代理连接再套同一代理；其它 TCP 通过该环境代理。UDP 均 SOCKS5 转发，HTTP 上拒绝。
- 路由注册在 WebView 创建之前完成；XPC 断连关闭该注册全部 flow，并将 token 放入拒绝集合直至 provider 停止，防止窗口尚存时恢复直连。Runner 收到断连立即退出；正常退出 invalidate XPC。扩展 stop 先关闭所有 flow 再 completion；代理控制连接 EOF/超时也关闭对应 UDP flow。每条 pump 有背压，不无限排队。

## 接入与发布边界

新增 `safarier network-extension install|status`：install 通过 OSSystemExtensionRequest 请求激活，然后保存并启动本 app 对应的 NETransparentProxyManager；status 只读。仅由用户显式运行 install，Runner 不弹权限/自动启用系统配置。

实验入口 `SAFARIER_EXPERIMENTAL_RTC_PROXY=1`：仅在代理环境且 RTC 没有被显式关闭时，Runner 在创建 WebView 前要求成功注册。未启用实验入口的代理环境若 RTC 开着则拒绝启动并给出说明，补上已发现的直接泄漏入口。已有关闭 RTC 的环境、直连环境和默认开关不迁移；已选关闭 RTC 的用户必须显式通过 `--spi default` 或编辑器启用后进行实验。注册失败不悄悄关闭 RTC，也不直连。

签名打包使用单独脚本，在已有 app bundle 上构建/嵌入扩展并按内到外签名。必须提供同团队宿主/扩展 provisioning profile、签名 identity 和 TEAM；校验 profile entitlement、bundle/team、过期时间。普通 ad-hoc 构建不携带未授权 entitlement，不触发激活。

## 不能靠单测证明的发布阻塞

1. WebKit flow 的 sourceAppAuditToken 是否归属 Runner 而非 WebKit 网络辅助进程。若不成立，不扩大匹配到所有 WebKit，必须重新设计归属。
2. Transparent provider 崩溃/被禁用时 OS 可恢复原路径；Runner 的断连退出存在竞态，不能宣称 OS 级 kill switch。正式发布必须用实测及必要的系统级阻断设计关闭这个窗口。实验开关不默认开启，PR 不能合并为生产完整修复。
3. NE 透明代理的 connect-by-name DNS 可能先由系统解析；本轮不宣称 DNS 隔离。
4. HTTP CONNECT 不能承载普通 UDP；成功通话须有可用 TURN/TCP，不能把 UDP 拒绝称作 HTTP 通话已通过。
5. TCP 代理端点 bypass 的主机名解析与 IPv6 表达需保守处理：只有准确匹配才放行；未匹配可能二次代理失败，但不能扩大 bypass 网段。

## 验收

- 协议单测：IPv4/IPv6/域名、恶意长度/FRAG、SOCKS 拒绝/认证失败、TCP 控制断连、异步超时、UDP 回复源保留。
- 本机真实 listener 集成：SOCKS5 mock 仅模拟外部服务器；真实客户端经 TCP 协商并通过 relay 双向传输，禁止直接目的 socket；认证/relay 拒绝和关闭可观察。
- 路由表：两个完整 audit token 对应不同代理，重复注册拒绝，撤销关闭/拒绝旧 token，PID 复用不继承。
- `swift test`、可执行目标构建、plist/shell 检查；不把 compile 视为系统扩展启动。
- 待签名：安装、两个并发环境/弹窗实际媒体传输、代理 UDP 证据、直接网络零包、代理断开/扩展崩溃/禁用/Runner 退出、恢复与撤销、其它应用无影响。

## 审查记录

原生 Codex / GPT-6.1 Sol 已完成独立方案审查，见 [审查报告](webrtc-proxy-review.md)。主 agent 采纳下列 D1–D5 并负责实现；该报告不是实现或系统安装验收。

## 主 agent 收敛（2026-11-04）

独立审查见 [webrtc-proxy-review.md](webrtc-proxy-review.md)，CONDITIONAL；采纳 D1–D5，以下为实现契约，替代上文未明确处：

- D1：listener/路由表由单个 provider 实例拥有，仅网络规则完成后启动 listener。ready=false 时注册失败。stop 先置 false，invalidate 全部连接/listener、清空路由凭据并关闭全部 flow，最后 completion。每代独立对象，不共享跨代注册；异步回调检查实例 ready/flow closed。Runner 注册在 geo execv 之后；连接错误/超时/中断/失效不重连，立即退出。
- D2：只实现 Developer ID 分发签名路径，host/extension 都声明 `app-proxy-provider-systemextension`，host 另声明 `com.apple.developer.system-extension.install`。共享 App Group 为 `TEAM.sh.safarier.proxy`，Mach service 为 `TEAM.sh.safarier.proxy.control`，双方 entitlement 声明该组，扩展 `NetworkExtension.NEMachServiceName` 使用该服务。client 用 `.privileged`。Info.plist 中 `SafarierTeamIdentifier` 仅接受 10 位大写字母/数字，requirement 在 resume 前设定。激活待批准/需重启均不继续启用 manager。脚本要求匹配 profile，签全部嵌套代码；不实现 Apple Development 混用路径。
- D3：纯路由决策：未注册/无效 token 返回 pass（无保护保证，R1）；撤销 token 返回 reject；注册 token 返回 route，只有 TCP 原始 host/remoteHostname 和端口准确等于代理时 bypass。IP 用 Network.IPv4Address/IPv6Address 正规化、域名大小写正规化，不能同端口放行。reject 必须返回 true 并关闭 flow，容量满/HTTP UDP/endpoint 无效同样处理。规则采用 nil remote/local 的合法全匹配加 127.0.0.1/32、::1/128；扩展要求 macOS 15，使用新 endpoint API，宿主普通功能仍 macOS 14。
- D4：工厂在 privacy.apply 后检查代理环境的实际报告。关闭 RTC 必须 `.active`，否则抛错阻止首个 WebView；弹窗准备后同样检查，不满足则 `createWebViewWith` 返回 nil。实验就绪由 Runner 持有的活连接传入工厂显式参数，默认 false；用户要求关闭 RTC 失败时不得用实验绕过。其它内部调用和测试要显式提供真实适配器或验证拒绝，不传假“已保护”布尔值凑通过。
- D5：ASSOCIATE 请求 0.0.0.0:0，relay 端口必须非零。零 relay 地址只替换为控制 TCP currentPath.remoteEndpoint 的实际 IP，不重新 DNS 解析；非零域名 relay 按协议处理。逐包目的/来源，任何畸形包终止该 association；单包最大 65,000 字节、每批至多 64 包且总计至多 1 MiB、每方向一个 pending read/write。握手 10 秒；正常 association 不设该空闲时限。TCP EOF、UDP error、撤销、stop 共用幂等 close，取消连接和 timer；TCP 转发双向半关闭，两个方向完成才释放。每实例至多 256 个累计注册 token（含撤销记录），耗尽拒绝新注册；每 Runner 128 flow、全局 1024 flow。拒绝集合不淘汰；DTO ≤16 KiB，用户名/密码各 ≤255 UTF-8 字节。仅信任同团队同 identifier 应用进程，不声称签名验证了 Runner 模式；UUID 仅为诊断标识。

R1–R4 仍为发布阻塞，不以本地测试、编译或 XPC 注册成功消除。

## 开发与复核步骤

1. 普通构建继续使用 `scripts/build-app.sh`，不会包含/激活扩展。扩展可单独编译：`swift build --product SafarierProxyExtension`。
2. 获得 Developer ID 签名身份及两个真实 profile 后，使用 `python3 scripts/package-network-extension.py --help` 查看参数。先带 `--check-only` 进行 profile/证书/权限校验，再打包到一个不存在的 `--output .../Safarier.app`。输入 app 保持不变。脚本不安装、不公证、不激活；没有 profile 时不能完成本步骤。
3. 把已签名 app 放到系统允许的位置后，显式运行其 `Contents/MacOS/Safarier network-extension install`，按系统批准/重启提示操作；`network-extension status` 只读配置状态，不证明路由成功。卸载/禁用使用系统设置，本 Draft 未增加自动卸载命令。
4. 开发验收时从该签名 app 的 CLI 执行 `SAFARIER_EXPERIMENTAL_RTC_PROXY=1 .../Contents/MacOS/Safarier launch PROFILE_ID --spi default`。`default` 保留 RTC；不要用 `all`，其中 `webrtc` 代表关闭 RTC。环境变量必须传到 Runner，不能对已经运行的 Runner 临时生效。显式开启并不消除下列发布阻塞。
5. 两个不同代理环境分别与测试端建立真实媒体通话，包含弹窗和网络进程重建；同时记录代理中继流量与目的端直连包。对 provider 崩溃/禁用、代理断开、控制连接 EOF、Runner 退出逐一做故障注入。必须先证明 flow token 归属，再讨论成功；没有直接包并不自动证明媒体仍工作。

`swiftc scripts/probe-webrtc-routing.swift -o /tmp/safarier-rtc-probe` 后分别运行 `... socks5` / `... http` 可重现原始 WKWebsiteDataStore 绕行。该探针只使用本机 listener；退出 0 表示确认 **原始绕行存在**，不是扩展修复通过，不会注册到扩展。

协议/入口验证：`swift test --filter 'SafarierProxyTests|WebViewConfigurationFactoryTests|DataStoreManagerTests|ProxyManagementTests|PopupPrivacyTests.testFailedPopupRTCProtection'`。
签名配置纯校验：`PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-network-extension-package.py`，使用合成字典验证拒绝条件，不生成 profile，不证明实际签名可用。

## 本轮验证记录（2026-11-04）

最终代码基于上游 main `90c78af`，只移入 WebRTC 提交；不包含原工作树的独立 UI 改动或误落分支的订阅提交。

- `swift test`：530 项，6 项跳过，0 失败（WebKit 130 / Proxy 10 / Network 119 / Core 116 / App 155）。跳过项沿用本机能力/缺少 sing-box 的测试条件。早期未修改代码的 UI 基线有失败，最终全量运行未复现；本变更未修复那些无关 UI 断言。
- Proxy 10 项包含真实 loopback SOCKS5 认证与双向 UDP、不同目的/来源保留、wildcard relay、控制连接 EOF、畸形 FRAG、认证拒绝、10 秒静默握手超时、HTTP UDP 提前拒绝、SOCKS/HTTP TCP 半关闭后反向数据，以及 codec/路由撤销/容量检查。
- `swift build -c release --arch arm64 --arch x86_64 --product SafarierProxyExtension`：通过；`lipo` 验证两种架构，两个切片都保留 plist 指定的 Objective-C provider 类。未运行/安装该扩展。
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-network-extension-package.py`：3 项通过；只验证合成字典与生成 plist，不代表真实 profile/签名验收。
- 当前基线探针对 SOCKS5、HTTP 各复现 1 个直接 STUN 包、0 个 RTC 代理连接、1 个 HTTPS 代理连接。它证明原始问题，**不是修复后的媒体证明**。
- `Safarier network-extension status`：未配置实验网络扩展；无系统配置写入。缺少 provisioning profiles，签名打包/激活/真实媒体/崩溃和禁用故障注入均未执行。R1–R4 保持开放。
