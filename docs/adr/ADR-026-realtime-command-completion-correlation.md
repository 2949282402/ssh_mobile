> 最新更新时间：2026-08-12

# ADR-026：Realtime Command Completion Correlation

## Status

Accepted for the native network v1 Realtime App Shell adapter.

## Context

`NetworkCommandGateway.sendCommand()` and the Realtime gateway return a queue-level
status. A successful enqueue does not prove that Rust completed `start` or `stop`.
Ignoring the later `NativeCommandResultEvent` can leave a session in a false
`negotiating` state, while setting `stopped` immediately after enqueue hides the
remaining native close work.

## Decision

- `NetworkRealtimeGateway.start()` and `stop()` return `NativeCommandTicket`, which
  carries the generated `commandId` and the queue acceptance status.
- `AppRealtimeSessionBackend` owns a bounded pending map from `commandId` to
  `Completer<SdkResult<void>>`. Only the matching `NativeCommandResultEvent` resolves
  the command Future; queue rejection returns immediately without adding a pending
  entry, and missing results terminate through a bounded timeout.
- `RealtimeSession` may enter local `starting` when `start()` is requested. The
  `negotiating`, `connected`, `restarting`, `stopped`, and `failed` lifecycle states
  are driven by the native state event. A successful stop command completes the
  stop Future but does not set `stopped` until native reports `closed`.
- Client/backend disposal cancels pending completers and timers, cancels the native
  event subscription, requests stop for active sessions through the SDK owner, and
  closes the SDK event stream. Late native results are ignored.

## Consequences

Features receive operation completion rather than queue acceptance while remaining
unaware of command IDs, native event types, SDP/ICE signaling, sockets, and native
media resources. The App Shell owns the correlation and timeout policy; the runtime
continues to own the native handle.

## Verification

The SDK, transport, and Full App test suites include queue rejection, native command
failure, successful start ordering, delayed close, command timeout, and disposal with
a late result. Package/App analyzers and formatting are part of the Step 2 gate; the
current WSL session cannot execute Flutter tests because its `flutter_tester` process
closes the local test HTTP loopback before loading the test isolate.
