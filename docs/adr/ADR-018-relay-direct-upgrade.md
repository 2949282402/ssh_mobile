> 最新更新时间：2026-08-15

# ADR-018：Relay-to-Direct Session Upgrade

## Status

Superseded on 2026-08-15：transport-network v2（[ADR-CONNECTION-LIFECYCLE-V2](ADR-CONNECTION-LIFECYCLE-V2.md)）
把 Relay→Direct 后台升级（`schedule_direct_upgrade` / `direct_upgrade_loop` /
2s background direct probe / `replace_route_if_current` 原子切换）从主链**移除**。
Connection 建立时选定 Direct 或 Relay，之后直到连接结束 Route 不变；Relay 断线
后重新 `ResolvePeer`，下一次可能直接变成 Direct。未来如需性能优化，单独实现
`RouteOptimizer`（只能是 optimization，不能成为正确性依赖）。

## Historical note

本 ADR 记录 v1 的 Relay-to-Direct Session Upgrade 决策（Relay 可用时后台探测
更优 Direct、稳定窗口后原子替换、失败不改当前 Route），保留仅供决策历史参考。
v2 不再进行 Relay→Direct 自动迁移。

## Context

A Relay route can be available before NAT candidates become reachable. Direct
probing must therefore improve a live Session without interrupting Relay data,
and a failed or incorrectly authenticated probe must not change the current
route.

## Decision

- A Relay-connected Session starts at most one native direct-upgrade task per
  `PeerId + SessionId`. The task stops when the Session is closed, replaced, or
  already direct.
- The task uses the current ranked candidate set and the same parallel,
  identity-bound QUIC checks as initial route selection. It never closes or
  replaces the shared Relay client while probing.
- A successful candidate must pass a short stable window. The Session manager
  then checks that the expected Session is still connected through Relay and
  atomically installs the authenticated QUIC Connection with
  `replace_route_if_current`.
- Only after the swap does the runtime recover Delivery messages, resume
  transfer Sessions, start direct receivers, and publish direct route metrics.
  A stale Session or failed guard closes the new Connection and leaves the
  previous Relay route unchanged.

## Consequences

Relay remains a working fallback while Direct is unavailable. A direct upgrade
does not create a new logical Session, so Delivery ACK state, transfer offsets,
and recovery epochs survive the route change. Existing direct-path metrics and
hysteresis continue to govern later direct candidate migration; no direct/
Relay oscillation is introduced by the background task itself.

## Verification

Native tests cover an atomic Relay-to-Direct promotion with a ready QUIC
Connection, direct probe/authentication failure while Relay remains eligible,
Session replacement guards, Delivery recovery, and transfer resume behavior.
