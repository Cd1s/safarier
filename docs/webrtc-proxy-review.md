# WebRTC 独立代理 Draft 设计审查

结论：**CONDITIONAL**。模块拆分、每个 Runner 独立路由、完整 audit token、HTTP UDP 明确拒绝及实验开关方向可接受；以下 D1–D5 须由主 agent 在对应实现前收敛并写回方案。可以继续协议层等不依赖这些决定的开发，并交付明确标注未验收的 Draft PR。当前不构成“WebRTC 代理已修复”、生产合并或发布许可。

审查角色：Review / 原生 Codex，任务 `rtc-design-review`，未分派。日期：2026-11-04（America/Los_Angeles）。

审查基线：隔离 worktree `/Users/ctrdh/Code/safarier-worktrees/webrtc-proxy`，分支 `fix/webrtc-proxy-draft`，HEAD `0574469b0246b38850d8e7361c101b38003b5c0e`；方案为 `docs/webrtc-proxy.md` 第 1–48 行，SHA-256 `3c904a848101e62287217969fe66a7e2d945688c46630af5b00da743d27c1ac3`。下文方案行号均指该快照。原 checkout 仅在父终端通知隔离之前读取，未写入；后续仓库证据均来自隔离 worktree。

## 必须先收敛的设计问题

### D1 / 高：XPC 存活不等于 provider 正在接管；注册成功必须绑定已就绪的 provider 实例

位置：方案第 17–20、24、26 行。

证据：本机 `NEProvider.h:124–149` 将系统扩展进程启动与 provider 实例化分开；`NEAppProxyProvider.h:34–47` 单独定义 provider start/stop。Apple 的 [Network Extension Provider Packaging](https://developer.apple.com/forums/thread/800887) 的 Process Lifecycle 明确指出，停止 provider 后系统扩展进程通常仍存活，下次启动创建新的 provider 实例。

影响：若 Mach listener 在进程级存活，`stopProxy` 只关 flow 并 completion，Runner 不一定发生 XPC 断连。此时注册、已有凭据和“成功连接”可能仍存在，而网络规则已撤销；只依赖 interruption/invalidation handler 退出不能覆盖正常 stop。还存在先注册成功、后应用规则失败，或旧实例迟到回调误改新实例的窗口。这是可通过设计与局部测试解决的确定性问题，不能全部归入“崩溃后 OS 行为待实测”。

具体修订：明确 listener 与 provider 实例的所有权和代际；只有当前实例 `setTunnelNetworkSettings` 成功、规则已就绪后，注册才能成功回复，Runner 才能创建 WebView。stop/start 失败先撤销 ready 状态、拒绝新注册、撤销该代全部路由与凭据、显式终止关联会话，再完成停止；客户端将 interruption、invalidation、注册调用错误和超时都作为失效，不自动重连继续浏览。回调须验证代际/关闭状态，不能复活旧路由。注册放在语言 `execv` 重启之后：现有 `RunnerMain.swift:73–98,151–164` 会先停 sing-box 再重执行。

验收补充：listener 活着但 provider 未启动、网络规则应用失败、stop 时 XPC 本身未断、stop 与注册交错、旧回调在新实例启动后到达，均不得产生“注册成功且没有接管”的状态。实机仍需验证 OS 切换时序，见 R2。

### D2 / 高：签名/XPC 接线缺少 App Group 与部署渠道的明确契约

位置：方案第 16–18、24、28 行。

证据：本机 `SystemExtensions.h:88–118` 从宿主 `Contents/Library/SystemExtensions` 发现扩展，激活可能等待用户批准或返回需重启；`NEProvider.h:124–149` 要求 `NetworkExtension.NEProviderClasses` 并调用 `startSystemExtensionMode()`。Apple DTS 的 [Mach service/App Group 校验说明](https://developer.apple.com/forums/thread/776759) 明确给出 `NEMachServiceName` 必须位于扩展声明的 App Group 命名空间之内。仅拼 TEAM 与 bundle ID 不等于已声明该 App Group。

具体修订：在现有方案中补齐宿主/扩展 entitlement 和 Info.plist 对照，确定实际 App Group、服务名来源及两端一致性。保留所定服务名可以，但须提供匹配的 App Group 声明与 profile 校验，不能只靠 TEAM 前缀；客户端按全局 Mach service 使用 `.privileged`，并保持双向签名校验。扩展需有正确 bundle 布局、provider 映射、入口和自身依赖，不能依赖宿主用户目录或相对到宿主的动态库。install 的“等待批准/需重启/失败”不得继续保存为已就绪或向 Runner 报成功；status 不触发安装或配置写入。

签名渠道须明确：Developer ID 路径的宿主和扩展都需要获 profile 授权的 `app-proxy-provider-systemextension`；Apple Development 路径采用对应无后缀值，不能混用。宿主另需系统扩展安装权限；签名脚本验证实际证书、App ID、TEAM、profile 有效期与 entitlement 相容性，按内到外重签包括现有 sing-box 在内的嵌套可执行代码。普通 `scripts/build-app.sh:167–171` 当前是 ad-hoc，不能据此判断 NE 可激活。[Apple 的 Developer ID 签名说明](https://developer.apple.com/forums/thread/737894) 支持独立签名脚本的方向；其当前修订已说明 Xcode 27 的改进，不应沿用“所有版本 Xcode 都不能正确导出”的旧结论。

验收补充：无需 profile 即可对生成 plist/entitlement、服务名前缀、不同渠道值、缺失/不相容输入和嵌套代码清单做静态检查。没有真实 profile 时签名/安装验收保持未执行；不得生成虚构授权或修改系统保护绕过。

### D3 / 高：明确透明代理回调的“放行”与“接管后拒绝”，以及规则匹配范围

位置：方案第 16、19–20、36 行。

证据：本机 `NETransparentProxyProvider.h:23–25` 明确：回调返回 `NO` 会直连，DNS/proxy settings 不生效，connect-by-name 不跳过系统解析；`NEAppProxyProvider.h:58–62,79–89` 要求接管者保留 flow。`NENetworkRule.h:143–166` 的全匹配不含 loopback；`NETransparentProxyNetworkSettings.h:36–43` 对规则方向、local network、wildcard/端口和 53 有限制。

具体修订：补一张同步决策表：无关未注册进程与精确 TCP 代理端点 bypass 才返回 false；命中已注册或拒绝集合的 token 后，HTTP UDP、容量耗尽、握手失败、无效 endpoint、关闭中等情况必须接管并关闭读写，不能返回 false。异步握手前即保留 flow，不因等待 XPC/网络工作阻塞全局回调。缺失/畸形 `sourceAppAuditToken` 无法安全猜归属：明确保持其它应用路由的同时，这一类无法获得保护证明，不能将其算作被保护的 Runner 流量。

明确采用合法的全匹配规则加显式 IPv4/IPv6 loopback 规则，不能用 wildcard 地址加 port 0 代替；不宣称覆盖系统 DNS。保留精确代理端点 bypass，但定义按端口和地址族正规化比较、域名与解析地址如何对应，不把任意同端口/同网段放行；无法证明相等则拒绝或代理失败。provider 自身与 sing-box 的出口不继承 Runner 路由，验证不会自递归。

验收补充：覆盖两种 UDP 回调的所支持 OS 入口、每条失败分支的接管/关闭结果、loopback 规则生成、IPv6 表达、无关应用放行、精确端点与近似端点。SDK 新 endpoint API 从 macOS 15 可用，项目最低 macOS 14；需保留可用性分支并处理新版 SDK 的废弃警告。

### D4 / 高：实验门禁必须看实际 RTC 禁用结果，不能只看配置位

位置：方案第 26 行；`Sources/SafarierCore/SPIFeatures.swift:16–17,29–34`；`Sources/SafarierWebKit/SPIPrivacyAdapter.swift:354–370`；`Sources/Safarier/Browser/BrowserSession.swift:192–215`。

证据：`disableWebRTC` 表示请求关闭。写入失败或回读仍为 YES 时，适配器返回失败状态/`degraded`；弹窗现有路径只记录隐私能力失效后继续创建 WebView。主配置的真实报告在 `WebViewConfigurationFactory.swift:175–180` 已可取得。

影响：若新门禁仅以 `spiFeatures.contains(.disableWebRTC)` 为“RTC 已关闭”的证明，未启用实验扩展的代理环境仍可能在 SPI 失效时暴露 RTC；默认配置位不能弥补该泄漏。弹窗也可能绕过仅检查首个窗口的门禁。

具体修订：定义代理环境进入首个 WebView、弹窗等真实入口的安全前提：实际报告确认 RTC 禁用，或满足本 Draft 所定义的实验代理就绪前提；否则拒绝创建/导航并说明原因。保留用户已选关闭的意图，失败时不要静默开启 RTC，也不要借失败自动进入实验路径。若主 agent 决定本轮不修既有 SPI 失效入口，必须明确缩窄第 26 行“补上直接泄漏入口”的覆盖声明，并将该缺口列为生产阻塞。

验收补充：注入 setter 失败、getter 失败、回读 YES、弹窗回读失败、正常 active、`--spi` 覆盖与实际订阅/自定义出站分支；以是否到达 WebView/导航入口为断言，不能只验证报错文字。

### D5 / 中：UDP association 的资源所有权正确，但端点和关闭语义仍不够确定

位置：方案第 15、20、40–41 行。

证据：本机 `NEAppProxyUDPFlow.h:39–69` 每次读取返回 datagram 与各自目的 endpoint，写回使用各自源 endpoint，不能只保存 initialRemoteEndpoint。[RFC 1928 第 6–7 节](https://www.rfc-editor.org/rfc/rfc1928) 区分 UDP ASSOCIATE 请求中的客户端地址、回复中的 relay 地址和每个包中的远端地址，并将 association 绑定 TCP 控制连接。

具体修订：在原有“一 flow 一控制 TCP 一 relay UDP”契约内补齐以下规则，不需要重设计模块：

- UDP ASSOCIATE 的请求地址是客户端预期 UDP 来源；未知时可发送零地址/零端口，不应把 STUN 目的地址作为该字段。方案“拒绝端口 0”须限定到目的包/有效 relay 等具体上下文，不能误拒协议允许的请求字段或 CONNECT 回复中的非目的字段。
- 对 relay 回复的 IPv4/IPv6/域名、零地址和端口确定策略：合法 relay 才可发送；零地址可选择明确拒绝，若兼容常见服务端则只替换为已建立 TCP 的实际 peer 地址，不重新解析到不相关地址。无论策略如何，均不能把 relay 失败转换为向最终目的地发裸 UDP。
- 同一 NE UDP flow 可有多个目的 endpoint；逐包编码、逐包保留回复源；使用实际连接的 relay 接收来源，区分外层 relay 与 SOCKS 头内远端。域名目的地址无须在本地解析后才编码；长度按字节校验。畸形包与非零 FRAG 的丢弃/终止策略应固定，不能透传。
- 控制 TCP 在协商后持续监测 EOF/error；区分握手超时与正常长时间空闲，不能按握手时限杀死已建立通话。明确 NE 读结束、UDP error、撤销、stop、超时的统一幂等关闭；取消 timer、控制/relay 连接和 pending read，忽略迟到回调，不遗留循环/凭据。
- 数量上限外，还需字节/批次上限、单向 pending read/write 上限。拒绝集合“直到 provider 停止”不可在长期运行中无限增长，也不能为了腾空间淘汰仍可能发包的 token：由主 agent 确定注册/代际预算与耗尽时拒绝新注册的策略。具体限额值可作为局部实现选择。

验收补充：真实 loopback mock relay 下，同一 flow 两个不同目的端点、外层错误来源、零地址 relay 策略、控制 EOF 与 UDP 回复/撤销竞态、关闭后迟到回调、容量拒绝且零目标直连。TCP 转发同时保留半关闭语义，不能收到一个方向 EOF 就丢掉另一个方向尚未送达的数据。RFC1929 用户名/密码按 UTF-8 字节长度验证，认证失败不得降级无认证；其线上认证不提供加密，内存不落盘不能被描述为链路加密。

## 信任边界复核

完整 audit token（含 pidversion）优于 PID；按 `sourceAppSigningIdentifier`、WebKit 名称或路径共享路由应继续禁止。当前使用双向 `setCodeSigningRequirement`、连接 PID/EUID 校验、自报完整 token 的动态代码校验，**不能仅因 token 来自请求就断言已存在可利用冒用漏洞**；但方案需明确验证顺序与权限范围：

1. 双方在 activate/resume 和任何敏感调用前设置 requirement；宿主和扩展分别用精确 identifier、预期 TEAM 与 Apple generic anchor，格式错误和空 TEAM 均失败关闭。本机 `NSXPCConnection.h:152–155` 说明 requirement 检查每条新消息，设置错误会抛异常，不能在已有未校验消息之后补设。
2. 在真实导出方法的同步上下文取得当前 connection，校验严格 token 长度、PID/EUID 和完整 token 对应的动态代码；`SecCodeCopyGuestWithAttributes` 只获取代码引用，还需以对应 requirement 执行 `SecCodeCheckValidity` 并检查结果（本机 `SecCode.h:127,135–189,217–237`）。不得退回 PID-only 查询、私有 `NSXPCConnection.auditToken` 或仅检查磁盘签名。
3. 写清信任的是“符合签名要求的本应用进程”，不是 profile UUID 对应的文件所有者，也不能靠签名证明进程正在 Runner 模式。profile UUID 只作诊断元数据；权限由经验证 token、EUID 和其连接控制，只能注册/撤销自己的 token；不能查询其它用户/连接的凭据或全局路由。无需为此新增全局 profile 授权服务。
4. 注册 DTO 限定编码类型和字段/总字节预算，检查 host/port/认证输入；密码不放回包或错误插值，不把用户名/密码加入一般 diagnostics。断连/撤销释放凭据引用；日志不打印 token 全值、代理口令或真实节点信息。

增加负例：错误 TEAM/identifier、同 PID 不同完整 token、错误 EUID、失效 token、重复注册、其它连接撤销、校验 API 失败、超大 DTO。纯路由表单测只能证明匹配逻辑，不能替代真实 XPC 与签名验证。

## 可保持为明确发布阻塞的事项

| 编号 | 当前判断与发布前证据 |
| --- | --- |
| R1：WebKit 归属 | 方案第 32 行保留正确。SDK 只承诺 flow 的 source app audit token，且该值可为 nil；没有证明安装系统 WebKit 的 STUN、TURN、媒体、弹窗、重建后的网络进程均回报 Runner 的完整 token。若实际为辅助进程，未注册放行策略会泄漏，实验开关不会自动修好。可以先做协议与接线 Draft；发布必须验证两个并发不同出站、不同用户/进程代际及辅助进程重建，归属不成立时回到主 agent 重新设计，不能扩大为所有 WebKit。|
| R2：OS 失效窗口 | 方案第 33 行保留正确。D1 能补正常生命周期错误，但 provider 崩溃、系统禁用、更新/睡眠恢复和规则撤销仍可能在 Runner 得知之前直连。XPC 退出与内存拒绝集合均非系统级 kill switch。发布需在对应受支持 OS 上持续发 STUN/媒体并强制故障抓包；有非零窗口就仍阻塞，不能将一次零包测量推广为所有时序保证。系统级阻断如需改变信任/资源边界，须另行具体设计与评审，本轮不擅自增加。|
| R3：签名与部署 | 无 provisioning profile，签名、激活、用户批准、规则真正安装、版本替换/恢复/撤销均未验收。编译、plist 合法和 ad-hoc `codesign --verify` 不能关闭此阻塞。获得实际 profile 后再做授权实机验收；公开分发另需正确 notarization 流程。|
| R4：通话与隐私范围 | HTTP CONNECT UDP 拒绝只能证明不转发 UDP，成功通话需实际 TURN/TCP；SOCKS/订阅需实际 UDP 双向媒体及远端协议支持。代理传输不自动消除所有 ICE 候选中的本机地址信息；不得承诺完整 WebRTC 匿名化。DNS 按方案第 34 行继续排除，不标记为 DNS 隔离。|

R1/R2 的未知结论本身不要求拒绝整个 Draft；前提是实验默认关闭、页面与 PR 不把“注册成功”显示为“RTC 保护已验证”，且未启用实验的泄漏入口按 D4 处理。本轮授权开发和 Draft PR，不包含实际执行 install、启用系统代理、签名实机验收或发布。

## 检查记录与交接

- 已读用户级规则、RTK、隔离 worktree 的 `CONTRIBUTING.md` 与方案；核对本机 `xcrun --show-sdk-path` 返回的 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`（`SDKSettings.json` 标识 macOS 27.0）。以 `rg`、`nl`、`sed` 只读核对上述 SDK 头文件和 Runner/WebKit/打包源码；SDK 头文件是声明证据，不能推导系统实机已工作。
- 官方证据仅使用 Apple 文档/DTS 与 RFC1928/1929；未把第三方方案当平台契约。定向 Nowledge 检索 `Safarier WebRTC NETransparentProxy audit token`（strict/default，limit 5）仅返回无关 NiceEval 项，未用于结论；未渲染图谱，因为无可用受相同 scope 约束的图谱工具/已验证浏览器身份。
- 未运行产品、`swift test`、网络 listener、激活/安装命令或系统配置变更。因本任务为设计 Review，以上验收条目均为建议/待执行，不报告测试 PASS。只写本审查文件；未操作 Git index、commit 或 push。
- 无本轮创建的 terminal/pane/tab/worktree；待回收资源：无。隔离 worktree 由父 agent 创建并继续管理。本审查不接管或回收父终端及其它任务资源。
