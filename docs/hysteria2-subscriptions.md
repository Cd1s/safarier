# Hysteria2 subscription compatibility

The reported endpoint returns a Clash YAML document whose sole proxy is Hysteria2 with a `ports` range and explicit `skip-cert-verify`. The URI-only parser mistakes `mixed-port` for a scheme; the bundled engine also omits QUIC.

This is an additive adapter to the existing SubscriptionNode / parameters contract, with no storage migration or resource ownership change. Parse YAML with Yams, import only the `proxies` entries (initially Hysteria2), and retain existing skip-count behavior for unsupported types. Never apply subscription DNS, listeners, rules or controller settings. Invalid supported entries fail the import with a sanitized error. URI/Base64 imports retain their existing behavior; Hysteria2 URI import is not part of this fix.

Add the `hysteria2` node type using existing password, TLS, serverName and parameters fields. Validate comma-separated ports and inclusive ranges (1–65535); retain the first port in serverPort for existing consumers and store normalized sing-box ranges in parameters. The builder emits server_ports instead of server_port for hopping. Preserve explicit TLS verification choice, SNI, ALPN and Salamander options. The bundled engine requires with_quic in addition to with_utls; packaging must reject an obsolete helper without QUIC.

Acceptance: sanitized block/flow YAML regression fixtures; mixed unsupported entries; malformed YAML, missing credentials and invalid ranges; generated sing-box config checks using the rebuilt engine; full Swift suite; fetch the reported subscription through the actual CLI in an isolated temporary workspace. Real proxy connectivity is a separate check and must not be inferred from import/config validation. Never commit the real subscription URL, credentials or server details.

References: https://sing-box.sagernet.org/configuration/outbound/hysteria2/ and https://github.com/jpsim/Yams .

## Verification (2026-11-04)

- `MISE_GO_VERSION=1.27.3 SINGBOX_ARCHS=arm64 bash scripts/build-singbox.sh`: passed; sing-box 1.14.4 reports `with_utls,with_quic`. Shell interpolation next to Chinese punctuation was fixed so the script completes on this host.
- `SAFARIER_SINGBOX="$PWD/out/sing-box/sing-box-arm64" swift test --filter SafarierNetworkTests`: 119 tests passed, including actual `sing-box check` and process lifecycle tests. A single port inside `server_ports` must be represented as `443:443`, verified against the real engine.
- CLI `sub add --url -` with the reported subscription in a temporary SAFARIER_HOME: imported one Hysteria2 node. A temporary live acceptance check started the engine and reached local SOCKS readiness, but the HTTPS connection test timed out. Remote usability is not confirmed. The temporary process, state and test source were removed.
- Full `swift test` attempt: Core 116 passed; WebKit 129 executed with one version-gated skip. The initial Network run found the single-port conversion error (fixed and rerun above), and also overlapped an engine rebuild (missing executable; fixed by running against the completed build). App tests reported page-load failures in `LiveMachineVerificationTests.testEnglishProfileKeepsBaseFontsAndHidesUnmatchedAssetsAndVendorFonts` and an assertion in `NavigationPreferencesTests.testEveryAllowedNavigationGetsAdvancedPrivacyBits`; the App test process was terminated while stalled. Full-suite success is not claimed, and those failures were not diagnosed as part of this subscription fix.
- `bash -n scripts/build-singbox.sh scripts/build-app.sh` and `git diff --check`: passed. Universal app packaging and GUI interaction were not run.
- Rebased delivery as an isolated commit on upstream `main`: the 26 parser, fetcher and config-builder tests passed again against the real QUIC-enabled engine.
