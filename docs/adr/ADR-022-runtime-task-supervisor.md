> 最新更新时间：2026-08-19

# ADR-022：Native Runtime Task Supervisor

> **V2 边界审计（2026-08-19）**：Runtime root cancellation、supervisor-owned
> task、显式 stop/join 和 native resource shutdown 仍然有效；本 ADR 中把
> reconnect、direct-upgrade、Delivery retry 或 transfer worker 归入旧
> ConnectionSession task group 的 v1 归属规则，已由
> [ADR-CONNECTION-LIFECYCLE-V2](ADR-CONNECTION-LIFECYCLE-V2.md) 与
> [ADR-BUSINESS-RECOVERY-V2](ADR-BUSINESS-RECOVERY-V2.md) 取代。v2 只把
> ConnectionSession-scoped carrier work 放入 session group，Delivery/Transfer
> recovery worker 由业务 manager 跨 transport 持有。

## 状态

Accepted for the native network v1 runtime.

## 背景

The native runtime had several independent `tokio::spawn` calls for QUIC
accept, peer receivers, reconnect, direct-upgrade probes, Delivery retry,
Relay reconnect, file transfer, and command dispatch. Some handles were stored
locally, but many were not owned by either the Runtime or the logical Session.
Aborting the command worker therefore did not prove that sockets, retry loops,
or stream receivers had exited before `NetworkRuntime::stop()` returned.

## 决策

- `RuntimeTaskSupervisor` is the only production owner that creates Tokio
  background tasks. It has a root cancellation signal and joins every
  registered task during shutdown.
- A logical `SessionId` maps to one child task group. Reconnect,
  direct-upgrade, path metrics, Delivery retry, channel receivers, file
  receivers, and transfer workers are registered against that group rather
  than against an individual Quinn `Connection`.
- Explicit Session close cancels and awaits that child group before returning.
  A Connection replacement keeps the Session group and Delivery state, so a
  route change does not create a second logical Session.
- Runtime shutdown changes lifecycle to `Stopping` before dropping the
  command sender, rejects new commands, cancels the supervisor root, closes
  Relay/WebRTC/QUIC owners, joins all supervisor tasks, and only then reports
  `Stopped`.
- The command worker is itself a supervisor-owned runtime task. Raw task
  handles remain private to the supervisor; bounded candidate races may use a
  local `JoinSet` whose surrounding task owns and joins it.

## 后果

`stop()` has a checkable completion boundary: no supervisor-owned listener,
Relay reconnect, Session reconnect, Delivery retry, direct-upgrade probe,
channel receiver, file receiver, or persistent WebRTC peer remains alive when
it returns. WebRTC `RealtimeIoDriver` tasks are registered under the logical
`realtime:<id>` Session group, and cancellation drops the UDP socket together
with the sans-I/O PeerConnection before the supervisor join completes.

The supervisor is deliberately native-only. Flutter receives no task handles
and cannot outlive or restart a Session child independently of the native
owner.

## 验证

`network-core` includes cancellation/join tests for runtime and Session tasks,
the loopback stop-and-rebind test, the active direct transfer/recovery tests,
and a 100-cycle create/start/bind/stop/recreate stress test. Privileged
`cargo test -p network-core --lib --locked --offline` and
`cargo clippy -p network-core --all-targets --locked --offline -- -D warnings`
pass.
