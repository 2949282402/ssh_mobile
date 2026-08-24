> 最新更新时间：2026-08-24

# ADR-029：v1 协议契约消费（Relay refresh、重试策略、Realtime 快照）

## Status

Superseded on 2026-08-15：本 ADR 记录的是 **v1 协议契约**的消费 wire shapes
（`NetworkErrorCode` 12/13、`RetryDisposition`、`NetworkError` 字段 5/6、
Realtime revision 快照、`POST /v1/devices/refresh`）。transport-network v2 以
[ADR-RELAY-DATA-PLANE-V2](ADR-RELAY-DATA-PLANE-V2.md) 的 Relay Protocol V2
（Protobuf Binary over WebSocket、`request_id` + `attempt_id` 关联）取代 v1 wire
契约；本 ADR 的 v1 错误码/重试/refresh/revision 形态不再作为当前契约权威。

## Historical note

本 ADR 保留 v1 协议契约的消费决策历史（Go Relay + Rust native codec + Dart
`network_sdk` + Flutter App 四层同步）。Realtime `revision` 的比较语义在 v2 命名
表中仍作为「Realtime 快照版本」保留（见
[ADR-TRANSPORT-NETWORK-V2](ADR-TRANSPORT-NETWORK-V2.md) 命名方案）；其余 v1
wire 形态随 v2 迁移删除。

`POST /v1/devices/refresh` 作为当前 Bootstrap HTTP API 仍然保留；其现行签名
时效性与硬切换契约由
[ADR-031-relay-refresh-proof-freshness.md](ADR-031-relay-refresh-proof-freshness.md)
统一定义，本 ADR 中无时间戳的历史请求形状不再可用。

## Context

Wave 1 left the Relay device plane and the native Realtime codec without typed
retry guidance or credential-refresh support. When a short-lived Relay
credential expired, the Flutter client could not silently renew it; it either
required a fresh enrollment token or blind-reconnected against a server that
had already rejected the credential. Realtime snapshots also lacked a signaling
revision, so a client could not distinguish a stale snapshot from the latest
state.

Wave 2 finalized five contracts across the Go Relay, the Rust native codec, the
Dart `network_sdk` package, and the Flutter App/Feature layer. This ADR records
those wire shapes and the consumption rules so each layer mirrors the same
behavior and no layer invents wire values.

## Decision

### The five contracts

1. **`NetworkErrorCode`** gains `credentialExpired(12)` and `identityConflict(13)`.
   `credentialExpired` means the presented Relay credential is stale and a
   refresh is possible without a token. `identityConflict` means the device
   identity cannot be enrolled/reused and retry must stop.
2. **`RetryDisposition`** enum (`unspecified`/`noRetry`/`retryWithBackoff`/
   `retryAfter`/`refreshCredentialThenRetry`) with `retryAfterSeconds`. The SDK
   `NetworkError.retryable` prefers disposition and falls back to the legacy
   code policy.
3. **Structured `NetworkError` wire fields**: field 5 `retry_disposition`,
   field 6 `retry_after_seconds`, alongside the existing code/message/
   operation/peer fields. The Dart data-plane codec and the native codec decode
   these; unknown future fields remain forward-compatible.
4. **Realtime revision + snapshot**: `RealtimeSessionStateChangedEvent` carries
   `revision`; `NativeRealtimeSnapshotEvent` (tag 23) carries
   `{realtimeId, peerId, state, revision, error}` and maps to the SDK
   `RealtimeSnapshotBackendEvent`/`RealtimeSnapshot`.
5. **`POST /v1/devices/refresh`**: request
   `{device_id, public_key, nonce, signature}` with an Ed25519 signature over
   `"POST\n/v1/devices/refresh\n"+nonce`. Success returns the enroll-shaped
   `{credential, expires_at, server_time, protocol_version}`. 404 means the
   device is not enrolled and must re-enroll; 401 means auth failed.

### Realtime revision comparison rules

The client (`_RealtimeSession._applyState`) reconciles every incoming
`revision` against its current recorded revision before mutating state:

- `revision == 0` (legacy/unspecified): the event **always applies** its state
  but **never advances** the recorded revision. Pre-revision backends keep
  working unchanged.
- `0 < incoming < current`: the event is **stale**; ignore it entirely — the
  state, the revision, and any `failed`/error marker are left untouched. A
  stale failure snapshot must not roll a `connected` session back to `failed`.
- `incoming == current`: **idempotent** re-application; state is applied, the
  recorded revision is not advanced.
- `incoming > current`: **apply** the state and advance the recorded revision
  to the incoming value.

State events and snapshots are published concurrently; the guard ensures a
late-arriving older snapshot never overrides a newer state.

### Four-layer sync

The Go Relay writes the error and refresh shapes; the Rust native codec mirrors
the `NetworkError` fields and the Realtime snapshot tag; the Dart `network_sdk`
exposes `BootstrapClient.refresh`, `RefreshRequest`, the retry types, and the
Realtime snapshot event; the Flutter App/Feature layer consumes them. Any wire
value change must update all four layers and the golden test data together.

### Refresh endpoint and signature proof

`RelayEnrollmentService.refreshCredential` reuses the persisted Ed25519 device
seed, generates a fresh 32-byte base64url nonce, and signs the fixed transcript.
The SDK maps 409 → `identityConflict`, 401 body-code 12 → `credentialExpired`,
and 404 → `noRoute` as the stable re-enroll signal. The Feature never parses
error message strings; it distinguishes re-enroll-needed by the typed code.

### Reconnect suppression on expired credentials

When a data-plane failure carries `credentialExpired` (or a
`refreshCredentialThenRetry` disposition), or a locally stored credential is
detected expired, the LAN receiver coordinator silently refreshes the
credential and reconfigures the native data plane instead of prompting for a
token. A 404/`noRoute` refresh failure stops automatic retry and marks the
device un-enrolled so the UI can prompt for a fresh enrollment token. The
reconnect scheduler honors `retryAfter` (server-suggested seconds, capped at
60s), `retryWithBackoff`/`unspecified` (1/2/4/8/16/30s exponential, ≤ 6
attempts), `refreshCredentialThenRetry` (refresh path), and `noRetry`/
`identityConflict` (terminal, no reconnect). Concurrent refreshes are coalesced
to prevent loops.

## Consequences

The Flutter client can renew short-lived Relay credentials without user tokens,
distinguish transient from terminal failures by typed code rather than message
strings, and surface an accurate re-enroll signal after a Relay restart. The
security invariant is preserved: refresh always requires a valid Ed25519
signature proof, `identityConflict` does not leak key material, and
re-enroll-needed paths never loop silently. Feature code that predates the
retry fields continues to see `unspecified` dispositions and unchanged behavior.

## Verification

- `network_sdk`: `flutter analyze --no-pub` and `flutter test --no-pub`
  (includes `BootstrapClient.refresh` success/404/409/401 mapping tests and the
  Realtime revision-guard scenarios in `realtime_test.dart`: stale lower
  revision ignored, stale `failed` snapshot ignored, equal-revision idempotent,
  newer revision applied, legacy `revision == 0` applies without advancing).
- `apps/ssh_mobile_full`: `flutter analyze --no-pub` and `flutter test --no-pub`
  (out-of-order revisioned snapshot/state through the Realtime adapter keeps the
  newer state).
- `feature_lan_share`: `flutter analyze --no-pub` and `flutter test --no-pub`
  (coordinator auto-refresh, disposition-driven backoff, `noRetry`/
  `identityConflict` terminal behavior, `RelayEnrollmentService.refreshCredential`
  signature proof and failure mapping).
- `apps/ssh_mobile_full`: `flutter analyze --no-pub` and `flutter test --no-pub`
  (data-plane codec decodes retry fields; Realtime adapter maps native
  snapshot/state revision and native error retry fields).
- Repository guards: `dart run tool/check_resource_owners.dart`,
  `dart run tool/architecture_check.dart`, and `git diff --check`.
