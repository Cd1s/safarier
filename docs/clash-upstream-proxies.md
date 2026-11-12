# Clash nodes and upstream latency

Clash YAML imports accept HTTP / HTTPS, SOCKS5, Shadowsocks / SS2022, VMess, Trojan, AnyTLS, VLESS (including Reality), Mieru, and Hysteria2. Remote subscriptions, pasted YAML, Base64 YAML, and the **Choose Clash YAML File…** button use the same parser. Existing URI imports remain available; Mieru uses Clash YAML, not a new URI format.

Only the `proxies` list is read. Global DNS, routing, groups, listeners, and controllers are never applied. Unsupported protocols are counted and skipped. Invalid supported nodes fail the import with a sanitized error; no YAML or credentials are echoed. Subscription caches and pasted source files are written with 0600 permissions.

| Protocol | Imported options | Runtime |
| --- | --- | --- |
| HTTP / HTTPS | Optional username / password, TLS, SNI, certificate verification, ALPN | sing-box |
| SOCKS5 | Optional username / password | sing-box |
| Shadowsocks / SS2022 | Cipher, password / keys, simple-obfs or v2ray-plugin options | sing-box |
| VMess | UUID, alterId, cipher, TLS, SNI, TCP / WebSocket / gRPC | sing-box |
| Trojan | Password, SNI, certificate verification, ALPN, TCP / WebSocket / gRPC | sing-box |
| AnyTLS | Password, SNI, certificate verification, ALPN | sing-box |
| VLESS | UUID, TLS, SNI, flow, client fingerprint, Reality public key / short ID, TCP / WebSocket / gRPC | sing-box with uTLS |
| Mieru | Username, password, TCP / UDP transport, multiplexing level | Official Mieru helper |
| Hysteria2 | Password, SNI, certificate verification, ALPN, port hopping, Salamander | sing-box with QUIC |

`ip-version` is retained. sing-box nodes map it to a local resolver's address-family strategy for the proxy server only. Mieru uses its native system resolver; the official CLI does not expose Clash's address-family preference. Website destinations continue through the proxy. The browser feature covers TCP web traffic, as before.

## Mieru lifecycle and packaging

Run `scripts/build-mieru.sh` before `scripts/build-app.sh`. The preparation script fetches pinned official Mieru 3.39.0 macOS arm64 / amd64 binaries, verifies each published SHA-256, and includes the GPL license and source location. Packaging requires both architectures, bundles the helper, and signs it with the application. For a development checkout, set `SAFARIER_MIERU` to the prepared executable.

A standalone Mieru node runs one foreground `mieru run` process with RPC and LAN access disabled. Configuration is passed through `MIERU_CONFIG_JSON_FILE`, with inherited `MIERU_CONFIG_FILE` removed. Raw helper output is suppressed because decoder errors may contain credentials.

For a Mieru upstream, traffic follows:

`WebKit → local sing-box SOCKS → local Mieru SOCKS → Mieru server → saved exit → website`

The two local helpers implement two remote hops. The sing-box exit detours through the loopback Mieru bridge; there is no direct or fallback outbound in the chain. Both helpers are stopped on cleanup. Each has its own identity-checked PID record and 0600 configuration; orphan recovery and workspace removal include the bridge's files.

## Latency semantics

Tests perform the existing certificate-verified HTTPS request to Cloudflare through a temporary local proxy. The displayed milliseconds are the HTTPS request's total duration, including proxy negotiation; helper startup time is excluded. They are not ICMP ping results or download-speed measurements.

Subscription tables and environment / upstream node pickers share results in memory. Users can test one node, all nodes, or the currently filtered picker list. A batch uses one temporary sing-box core and one parallel curl process; authenticated local SOCKS users route each request to its own node. All requests start concurrently (curl's limit is 10,000), results appear as each finishes, and each request has an eight-second deadline. Mieru nodes retain their dedicated helper bridges. Cancelling stops the batch and removes its private files before a retry starts. Opening a picker never starts a test automatically. Cancelled, refreshed, deleted, or externally modified nodes cannot publish stale results. Failures retain a sanitized explanation in the tooltip. Results are not written into subscriptions. Refreshing a subscription also reports any unsupported nodes that were skipped.

Subscription tables and the shared environment / upstream node picker default to ascending latency and re-sort as results arrive. Click the **HTTPS Latency** heading to switch between ascending and descending durations. Successful nodes come first, untested / queued / running nodes follow, and failed nodes always stay last in either direction. Equal durations and unfinished or failed nodes retain their order from the subscription. Picker search filters this sorted list; **Test Listed Nodes** tests all matches, including rows outside the visible scroll area. An empty search tests the entire subscription.

The upstream editor measures only the chosen upstream. The saved exit's existing **Test Connection** action measures the complete chain and displays the final exit IP; its result also appears in the proxy sidebar.

## Validation

Regression tests cover mixed block / flow YAML, Reality and TLS options, invalid supported entries, unsupported entries, Base64 and local imports, private storage, node-test concurrency / cancellation / stale results, and actual Mieru startup and cleanup. Generated sing-box configurations are checked against the real engine. Native helper tests require `SAFARIER_MIERU`; they skip explicitly when the helper is unavailable. Set `SAFARIER_MITA` to a locally built official Mieru server to also run the loopback HTTPS test: standalone Mieru, an authenticated HTTP exit through Mieru, and fail-closed behavior after the Mieru server stops. This fixture binds only 127.0.0.1 and uses a temporary CA; it does not change the system trust store.

Real subscription files, node names, servers, passwords, UUIDs, and keys are never included in fixtures or PR content. Live service availability is separate from parsing and configuration validation.
