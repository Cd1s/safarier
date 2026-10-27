## What does this change? / 改动说明

<!-- What problem does it solve? Link the issue: Fixes #123 / 解决了什么问题？关联 Issue：Fixes #123 -->

## Core constraints / 核心约束自检

- [ ] No script injected into web pages to alter the DOM or prototypes (`WKUserScript` etc.). / 未向网页注入任何篡改 DOM / Prototype 的 JS 脚本。
- [ ] Native Engine Bridge: runtime signatures and capabilities verified, calls go through `SafarierObjCSupport`, writes are read back, and unavailable capabilities degrade safely. / 若涉及原生引擎桥接层：已完成运行时方法签名与能力核验，经 `SafarierObjCSupport` 调用，写后回读，能力缺失时安全降级。
- [ ] Proxy / subscription routing (if touched) stays fail-closed (never falls back to direct), and no password or key appears in command-line arguments or logs. / 若涉及代理或订阅路由：保持 Fail-Closed（断连不回退直连），命令行参数和日志里没有密码或密钥。

## Verification / 验证方式

- [ ] `swift test` passes (paste the last lines) / `swift test` 通过（贴最后几行）
- [ ] `safarier probe <PROFILE_ID>` output or manual UI check, if behavior changed / 行为有变化时，附 probe 输出或界面实测记录

```text

```
