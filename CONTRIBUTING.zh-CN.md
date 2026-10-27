# 参与贡献 Safarier

[English](CONTRIBUTING.md) · **简体中文**

感谢参与。Safarier 是基于真 macOS Safari 内核的多环境浏览器，每个改动都必须保证它和 Safari 无法区分。写代码前请先读完下面三条原则。

## 1. 核心设计原则

### 真 Safari 原生一致性：零 JS 注入

所有环境特征都来自系统 WebKit 和进程级设置，不用脚本伪造：

| 特征 | Safarier 的做法 |
|---|---|
| UA、Safari 专有接口 | `applicationNameForUserAgent`、WebKit 偏好设置 |
| 语言 | 进程级 `-AppleLanguages`（跟随代理时 Runner 会带新参数重启自己） |
| 时区 | 原生引擎桥接层的时区配置 + `TZ` |
| P3 / HDR 屏幕、devicePixelRatio | 原生引擎桥接层的屏幕能力与像素比配置 |
| 字体隔离 | 原生引擎桥接层的字体允许集合与 Safari 兼容字体策略 |
| Canvas / WebGL / Audio 加噪 | Safari 高级指纹保护 |

- 不要加 `WKUserScript`，也不要用任何方式改动网页的 DOM、原型链或 `navigator` 的值。
- 只有用户主动操作时（用 Google 搜索所选文字、存储为），才允许在独立脚本环境（`WKContentWorld.defaultClient`）里只读取值，网页看不到。
- `safarier probe` 在自己的空白页里运行一段只读的测量脚本，它是诊断工具，不参与正常浏览。

### 原生引擎桥接层：运行时方法签名与能力核验

需要运行时查找的能力统一经原生引擎桥接层（Native Engine Bridge / `SafarierObjCSupport`）实现，并满足三条：

1. **先做运行时方法签名与能力核验**：在目标 macOS / WebKit 版本上检查方法可用性、类型编码和调用约定。通过运行时签名检查记录验证结果，并附在 PR 里。
2. **只经 `SafarierObjCSupport` 调用**：它先检查 `respondsToSelector:` 和类型编码，在 `@try` 里调用，失败时返回状态而不是崩溃。写入之后要回读校验。
3. **安全降级**：不认识的 macOS / WebKit 版本必须报 `unavailable` 或 `degraded`，并保持公开 API 的行为。`fontlist` 这类和版本强相关的能力，维护一份已验证 WebKit 版本的白名单。

### 代理严格 Fail-Closed 与凭据安全

- 每个环境走自己的 `sing-box` 进程（订阅节点），或 `WKWebsiteDataStore.proxyConfigurations`（独立 SOCKS5 / HTTP CONNECT 代理）。代理断了页面就加载失败，**绝不退回直连**。
- 密码存在钥匙串里。辅助进程拿凭据只经标准输入（curl 的 `-K -`，管道设 `F_SETNOSIGPIPE`）或权限 `0600` 的配置文件，绝不出现在命令行参数、日志或错误信息里。
- 测试和文档只用 `example.com` / `.invalid` 域名和 RFC 5737 / 3849 的示例地址，不用真实节点。

## 2. 代码结构导览

| 模块 | 负责什么 |
|---|---|
| `SafarierCore` | 数据模型与存储：`Profile`、`ProxySettings`、`Subscription`、`MacDeviceModel` 机型库、SPI 开关、Runner 启动参数、环境锁、钥匙串。只依赖 Foundation。 |
| `SafarierNetwork` | 订阅解析（SS / SS2022、VLESS / Reality、VMess、Trojan、AnyTLS、SOCKS），`sing-box` 配置生成与进程管理，跟随代理的 GeoIP（`ProxyGeoResolver`）。 |
| `SafarierWebKit` | 组装 `WKWebViewConfiguration`：数据存储、代理、公开的隐私设置、`SPIPrivacyAdapter`、机型与屏幕模拟、字体白名单规划。 |
| `SafarierObjCSupport` | 原生引擎桥接层：负责selector 与类型检查、`@try`、方法替换、C API 桥接。 |
| `Safarier` | 应用本体。`ManagerGUI`（SwiftUI 管理器）、`ManagerCLI`（`safarier profile/proxy/sub/...`）、`Browser`（Safari 式窗口、标签、菜单、右键菜单）、`RunnerMain`（每个环境一个 Runner 进程）、`ProbeController`。 |

同一个二进制，不带参数是管理器，带子命令是命令行，`run --profile <ID>` 是 Runner。每个环境运行在独立进程里。

运行时数据在 `~/Library/Application Support/Safarier/`。测试时可以用 `SAFARIER_HOME` 换到临时目录：

| 路径 | 内容 |
|---|---|
| `profiles.json`、`proxies.json`、`subscriptions.json` | 元数据（不含密码，密码在钥匙串里） |
| `subscriptions-inline/<ID>.txt` | 直接粘贴当作订阅的节点链接（权限 `0600`） |
| `logs/<PROFILE_ID>.log` | Runner 日志：`[capability]`、`[spi]`、`[geo]`、`[load-error]` 等行 |
| `locks/`、`sing-box/` | 每个环境的锁文件，以及运行中 `sing-box` 的配置和 pid |

常见改动该改哪里：

- **新增机型**：`MacDeviceModel.presets` 和 `MacDeviceModelTests`（视口按点、像素比、P3 / HDR、EDR 余量）。
- **新协议或新链接格式**：`SubscriptionParser` 和 `SingboxConfigBuilder`，加解析测试，并在 `testGeneratedConfigsPassSingboxCheck` 里加一例。
- **新的 WebKit 能力**：加一个 `SPIFeatures` 开关，在 `SPIPrivacyAdapter` 里加一个分支并报告 `CapabilityState`，用注入的桥写测试（参考 `FontAllowlistAdapterTests`）。

## 3. 本地构建与验证流程

需要 macOS 14 及以上和较新的 Xcode（Swift 5.10+）。只有重新编译自带的 `sing-box` 才需要 Go。

### 单元测试

```sh
swift test
```

全部测试必须通过，编译不能有警告。部分测试会用真实的 WebKit，部分会对生成的配置跑 `sing-box check`（找不到 `sing-box` 时自动跳过）。

### 无头探针

```sh
swift run Safarier profile list                 # 或 /Applications/Safarier.app/Contents/MacOS/Safarier
swift run Safarier probe <PROFILE_ID> [--url https://example.com] [--spi afp,tz,safari,fontlist]
```

探针会为这个环境启动一个真的 Runner，载入页面后输出一份 JSON：

- `capabilities.<能力>.state`：`advancedPrivacyProtections`、`proxy`、`timeZone`、`languages`、`fontAllowlist`、`displayCapabilities`、`deviceModel` 等每一项的状态：
  - `active`：已生效，并已验证（或回读一致）；
  - `degraded`：调用失败或回读不一致，保持公开行为；
  - `unverified`：已设置，但没法回读；
  - `unavailable`：这台机器的 macOS / WebKit 没有这个接口；
  - `notRequested`：这个环境没开。
- `observed.main` / `observed.worker`：网页在主线程和 Worker 里实际读到的值（语言、时区、屏幕、`devicePixelRatio`、媒体查询、Canvas 哈希等）。进程级设置在两边必须一致。
- `outbound`、`process`、`environment`、`spi.diagnostics`：实际走的出站、进程的语言和时区、macOS / WebKit 版本，以及每一步原生引擎桥接的能力记录。
- 退出码：`0` 成功，`2` 超时，`3` 页面载入失败（例如用 `--url` 时代理断开，Fail-Closed），`4` 测量脚本执行失败。

改动涉及环境模拟、隐私或代理行为的 PR，请附上相关的探针输出。

### 打包应用

```sh
scripts/build-singbox.sh                        # 交叉编译 darwin/arm64 + amd64 的 sing-box（需要 Go）
SAFARIER_ARCH=universal scripts/build-app.sh    # universal | arm64 | x86_64 → dist/Safarier.app
```

`SAFARIER_VERSION` 覆盖版本号，`SAFARIER_ICON_STYLE` 选图标（`meridian`、`prism`、`titanium`、`shield`）。应用是 ad-hoc 签名，可以用 `codesign --verify --deep --strict dist/Safarier.app` 和 `lipo -archs` 检查。

## 4. 提交 Issue 与 PR 指南

**Issue**：使用「问题反馈」或「功能建议」表单，写明 macOS 版本、芯片、出站方式、模拟机型和语言时区设置。敏感信息一律脱敏：不贴订阅链接、节点链接、密码和真实 IP。

**Pull Request**：

1. 一个 PR 只解决一个问题，改了的行为都要加或更新测试。
2. 填写 PR 检查清单：没有页面脚本，运行时方法签名与能力已核验且能安全降级，代理仍然 Fail-Closed，参数和日志里没有密钥。
3. 贴上 `swift test` 的最后几行。涉及环境模拟或代理的改动，再附探针输出或界面实测记录。
4. 照周围代码的风格写：注释用平实的话说明为什么这样做，界面文案和其它界面一样用中文。
5. 原生引擎桥接层的改动，先开 Issue 附上运行时方法签名与能力核验结果，再写代码。

自带的 `sing-box` 是未修改的上游代码，许可证为 GPL-3.0-or-later。`scripts/build-singbox.sh` 会把确切的源码 commit 和编译参数写进 `SOURCE`，随应用放在 `Contents/Resources/ThirdParty/sing-box/`。如果改了编译方式，请同步更新这份说明。
