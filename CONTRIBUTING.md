# Contributing to Safarier

**English** · [简体中文](CONTRIBUTING.zh-CN.md)

Thanks for helping. Safarier is a multi-environment browser built on the real macOS Safari engine, so every change has to keep it indistinguishable from Safari. Please read the three principles below before writing code.

## 1. Core Principles

### Native Safari consistency — zero JS injection

Every environment trait comes from system WebKit and process-level settings, never from scripts that fake values:

| Trait | How Safarier does it |
|---|---|
| User agent, Safari-only APIs | `applicationNameForUserAgent`, WebKit preferences |
| Language | process-level `-AppleLanguages` (the Runner relaunches itself when following the proxy) |
| Time zone | Native Engine Bridge time-zone configuration + `TZ` |
| P3 / HDR screen, devicePixelRatio | Native Engine Bridge screen capability and pixel-ratio configuration |
| Font isolation | Native Engine Bridge font allowlist and Safari-compatible font policy |
| Canvas / WebGL / Audio noise | Safari Advanced Fingerprinting Protection |

- Never add a `WKUserScript` or anything else that changes the DOM, prototypes or `navigator` values.
- Read-only evaluation in an isolated content world (`WKContentWorld.defaultClient`) is allowed only for user-initiated actions (search the selection, Save As). Pages cannot see it.
- `safarier probe` runs a read-only measurement script in its own blank page. It is a diagnostic, not part of browsing.

### Native Engine Bridge: runtime signature & capability verification

Capabilities that require runtime lookup belong in the Native Engine Bridge (`SafarierObjCSupport`) and must:

1. **Verify runtime signatures and capabilities first.** Check method availability, type encodings and the ABI on each supported macOS / WebKit version. Use runtime signature checks and record capability results in the PR.
2. **Be called through `SafarierObjCSupport` only.** It checks `respondsToSelector:` and the type encoding, calls inside `@try`, and returns a status instead of crashing. Read the value back after writing it.
3. **Degrade safely.** Unknown macOS / WebKit versions must report `unavailable` or `degraded` and keep public behavior. Version-gated features such as `fontlist` keep an explicit allowlist of verified WebKit versions.

### Proxy fail-closed and credential safety

- Each environment routes through its own `sing-box` process (subscription nodes) or `WKWebsiteDataStore.proxyConfigurations` (standalone SOCKS5 / HTTP CONNECT). If the proxy is down, the page fails to load. **Never fall back to a direct connection.**
- Passwords live in the Keychain. Helper processes get credentials through stdin (curl's `-K -`, with `F_SETNOSIGPIPE` on the pipe) or a `0600` config file. They never go into command-line arguments, logs or error messages.
- Tests and docs use `example.com` / `.invalid` hosts and RFC 5737 / 3849 addresses, never real nodes.

## 2. Project Structure

| Module | Responsibility |
|---|---|
| `SafarierCore` | Models and storage: `Profile`, `ProxySettings`, `Subscription`, `MacDeviceModel` presets, SPI feature flags, Runner launch spec, profile locks, Keychain. Foundation only. |
| `SafarierNetwork` | Subscription parsing (SS / SS2022, VLESS / Reality, VMess, Trojan, AnyTLS, SOCKS), `sing-box` config and process lifecycle, follow-proxy GeoIP (`ProxyGeoResolver`). |
| `SafarierWebKit` | `WKWebViewConfiguration` assembly: data stores, proxy, public privacy settings, `SPIPrivacyAdapter`, device and display simulation, font allowlist planner. |
| `SafarierObjCSupport` | Native Engine Bridge: the boundary for selector and type checks, `@try`, swizzles, C-API bridges. |
| `Safarier` | The app binary. `ManagerGUI` (SwiftUI manager), `ManagerCLI` (`safarier profile/proxy/sub/...`), `Browser` (Safari-style windows, tabs, menus, context menus), `RunnerMain` (one Runner process per environment), `ProbeController`. |

The same binary is the manager (no arguments), the CLI (subcommands) and the Runner (`run --profile <ID>`). Each environment runs in its own process.

Runtime data lives in `~/Library/Application Support/Safarier/`. Set `SAFARIER_HOME` to use a scratch directory while testing:

| Path | Contents |
|---|---|
| `profiles.json`, `proxies.json`, `subscriptions.json` | Metadata (no passwords; those are in the Keychain) |
| `subscriptions-inline/<ID>.txt` | Node links pasted directly as a subscription (`0600`) |
| `logs/<PROFILE_ID>.log` | Runner log: `[capability]`, `[spi]`, `[geo]`, `[load-error]` lines |
| `locks/`, `sing-box/` | Per-environment lock files, and `sing-box` configs / pids while running |

Common changes and where they go:

- **New device preset**: `MacDeviceModel.presets` plus `MacDeviceModelTests` (viewport in points, scale, P3 / HDR, EDR headroom).
- **New node protocol or link format**: `SubscriptionParser` plus `SingboxConfigBuilder`, with a parser test and a case in `testGeneratedConfigsPassSingboxCheck`.
- **New WebKit capability**: an `SPIFeatures` token, a branch in `SPIPrivacyAdapter` reporting a `CapabilityState`, and tests with injected bridges (see `FontAllowlistAdapterTests`).

## 3. How to Build & Verify

Requirements: macOS 14+ and a recent Xcode (Swift 5.10+). Go is only needed to rebuild the bundled `sing-box`.

### Unit tests

```sh
swift test
```

All tests must pass with no compiler warnings. Some tests use real WebKit, and some run `sing-box check` against generated configs (they are skipped when no `sing-box` is found).

### Headless probe

```sh
swift run Safarier profile list                 # or /Applications/Safarier.app/Contents/MacOS/Safarier
swift run Safarier probe <PROFILE_ID> [--url https://example.com] [--spi afp,tz,safari,fontlist]
```

The probe launches a real Runner for that environment, loads a page and prints one JSON document:

- `capabilities.<feature>.state`, for each of `advancedPrivacyProtections`, `proxy`, `timeZone`, `languages`, `fontAllowlist`, `displayCapabilities`, `deviceModel` and so on:
  - `active`: applied and verified (or read back);
  - `degraded`: the call failed or the read-back differs; public behavior is kept;
  - `unverified`: applied, but cannot be read back;
  - `unavailable`: this macOS / WebKit doesn't have it;
  - `notRequested`: turned off for this environment.
- `observed.main` / `observed.worker`: what the page actually sees on the main thread and in a Worker (languages, time zone, screen, `devicePixelRatio`, media queries, Canvas hash…). Process-level settings must match in both.
- `outbound`, `process`, `environment`, `spi.diagnostics`: the route used, the process language / time zone, macOS / WebKit versions, and every SPI step.
- Exit code: `0` OK, `2` timeout, `3` page failed to load (for example `--url` through a proxy that is down — fail-closed), `4` measurement script failed.

Attach the relevant part of the probe output to any PR that changes simulation, privacy or proxy behavior.

### Package the app

```sh
scripts/build-singbox.sh                        # cross-compiles darwin/arm64 + amd64 sing-box (needs Go)
SAFARIER_ARCH=universal scripts/build-app.sh    # universal | arm64 | x86_64 → dist/Safarier.app
```

`SAFARIER_VERSION` overrides the version and `SAFARIER_ICON_STYLE` picks the icon (`meridian`, `prism`, `titanium`, `shield`). The app is ad-hoc signed. Check it with `codesign --verify --deep --strict dist/Safarier.app` and `lipo -archs`.

## 4. Submitting Issues & PRs

**Issues**: use the Bug report or Feature request form. Include the macOS version, chip, outbound type, device model and language / time-zone settings. Redact everything sensitive: no subscription URLs, node links, passwords or real IPs.

**Pull requests**:

1. Keep each PR focused on one problem, and add or update tests for every behavior you change.
2. Fill in the PR checklist: no page scripts, runtime signatures and capabilities verified with safe fallback, proxy still fail-closed, no secrets in arguments or logs.
3. Paste the end of your `swift test` output. For simulation or proxy changes, also attach probe output or a manual check.
4. Follow the surrounding code style. Comments explain *why* in plain words, and user-facing strings stay in Chinese like the rest of the UI.
5. Changes to the Native Engine Bridge need an issue with runtime signature and capability verification results first.

The bundled `sing-box` is unmodified upstream code under GPL-3.0-or-later. `scripts/build-singbox.sh` writes the exact source commit and build flags to `SOURCE`, which ships in `Contents/Resources/ThirdParty/sing-box/`. Keep that notice accurate if you change how it is built.
