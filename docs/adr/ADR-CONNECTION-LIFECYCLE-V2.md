> 最新更新时间：2026-08-15

# ADR-CONNECTION-LIFECYCLE-V2：连接生命周期重构（ConnectivityAttempt 一次性、ConnectionSession 可丢弃）

## Status

Accepted for the transport-network v2 breaking refactor (2026-08-15). Companion
to ADR-TRANSPORT-NETWORK-V2; implements design doc §11-§15, §18, §34-§37 and
Steps 5-6, 8.

## Context

v1 has many connect entry points (`connect_peer`, `run_candidate_punch`,
`direct_upgrade_loop`, `migrate_direct_path`, `accept_connections`,
`accept_tcp_connections`), a global `candidate_attempts` map, a `PathManager`
that persists remote discovery truth (`remote_generation` +
`remote_attempt_id` + the whole remote candidate set), a logical `Session` that
survives transport loss with crypto-root continuity, and background
reconnect / direct-upgrade / path-migration tasks. Every one of these v2
deletes or re-scopes.

## Decision

### ConnectionOrchestrator 是唯一连接入口

所有连接必须进入 `ConnectionOrchestrator::connect()`，固定状态机：

```text
IDLE → RESOLVING → RESOLVED → COORDINATING
  → DIRECT_CONNECTING → CONNECTED_DIRECT
  → DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING → CONNECTED_RELAY
```

不存在 `RECONNECTING` / `DIRECT_UPGRADING` / `PATH_REPAIRING` 长期状态。

### ConnectivityAttempt 是一次性独立对象

```text
ConnectivityAttempt {
    attempt_id
    peer_id
    local_runtime_epoch
    remote_runtime_epoch
    remote_discovery_revision
    local_candidates
    remote_candidates
    started_at
    direct_deadline
    state
}
```

- 生命周期：`Resolve → 创建 Attempt → Candidate coordination → Direct connect
  → 成功/失败 → Attempt 销毁`。
- Candidate 完全 attempt scoped：`CandidateSet` 只属于本次连接尝试。
- **禁止**：Attempt 1 的 remote_generation 影响 Attempt 2；Attempt 1 的
  remote_attempt_id 留在全局 PathManager；Presence Event 删除当前 Attempt。
- 删除 `network-nat` 的 persistent `remote_generation` / `remote_attempt_id`。

### PathManager 仅保留 metrics

- 拆分出 `ConnectionPathMetrics`（只属于已建立连接的 RTT / Jitter / Loss /
  Endpoint）。
- 允许 `HistoricalPathMetrics` 作为性能提示，但**历史性能永远不能决定
  Candidate 是否仍然有效**。
- PathManager 不再保存远端 Discovery Truth；远端候选权威来自 Resolve 返回的
  `DiscoverySnapshot`。

### ConnectionSession 与 Transport 同生命周期（可丢弃）

- `Transport Connection 建立 → Identity Auth → Noise E2EE → ConnectionSession →
  Transport Lost → ConnectionSession Destroyed`。
- 重新建立 = `New Connection → New ConnectionSessionId → New Noise Root`。
- **禁止试图恢复旧 Socket 的 CryptoContext**，禁止跨 Transport 的 Session
  连续性 / route migration 连续性 / crypto root 连续性。
- 删除 `SessionState::Disconnected` 存活 + `should_reconnect` + `reconnect_loop`
  复用同一 `SessionId` + `SessionCryptoDecision::ContinueExisting` 的 crypto
  root 复用。

### Direct First 顺序建连（4s 窗口）

- 连接前先 `ResolvePeer`（2s 上限），再候选信令，再 **Direct First 4s**。
- 4s 内任一 identity-authenticated + E2EE-ready 的 Direct 成功 → `CONNECTED_DIRECT`。
- 4s 超时 → `DIRECT_FAILED` → `ReserveRelay` → Relay Data。**Relay 不再和
  Direct 并行抢跑**（无 happy-eyeballs 并行 Relay 启动）。

### 不再进行 Relay → Direct 后台升级

- 第一阶段删除 `schedule_direct_upgrade` / `direct_upgrade_loop` / 2s
  background direct probe / Relay → Direct auto migration。
- Connection 建立时选定 Direct 或 Relay，之后直到连接结束 **Route 不变**；
  Relay 断线后重新 Resolve，下一次可能直接变成 Direct。
- 未来如需性能优化，单独实现 `RouteOptimizer`，它只能是 optimization、
  不能成为正确性依赖。QUIC 自身 Path Migration（WiFi→5G 同一 authenticated
  QUIC Connection 内）是 Transport 内部优化，第一轮重构不要求实现。

### 连接重用规则

每次新的 `connect()` 都 Resolve；Resolve 后若当前已有 Healthy Connection 且
peer `runtime_epoch == Resolve 返回 epoch` 且 capability 满足本次业务，允许
重用现有 Connection。epoch 不一致 → Close old → New ConnectivityAttempt。

## Consequences

- 没有隐藏的透明重连 / DirectUpgrade / RepairPath / RestoreRoute；每次
  Transport 断开后业务显式重新 Resolve。
- Presence Event 无权修改 ConnectivityAttempt / CandidateSet /
  ConnectionSession；UI 提示与实际建连状态解耦。
- 大流量 Relay Data 不会与 signaling 共享 socket/queue（见
  ADR-RELAY-DATA-PLANE-V2）。

## Verification

按 Main 基线版 §40 测试矩阵的 Connection / NAT / Concurrency 组执行：每次
新 connection 先 Resolve、existing connection + same epoch reuse、existing
connection + new epoch 不复用、QUIC direct success/timeout、TCP / WebSocket /
Relay fallback、identity mismatch、同时连接多个 peer、同 peer 多 connect 合并、
stale/delayed attempt answer。
