> 最新更新时间：2026-08-22

# ADR-CONNECTION-LIFECYCLE-V2：连接生命周期重构（ConnectivityAttempt 一次性、ConnectionSession 可丢弃）

## Status

Accepted for the transport-network v2 breaking refactor (2026-08-15), clarified
2026-08-22 to match the implemented Stage A/B ordering. Companion to
ADR-TRANSPORT-NETWORK-V2; implements design doc §11-§15, §18, §34-§37 and
Steps 5-6, 8.

## Context

v1 has many connect entry points (`connect_peer`, `run_candidate_punch`,
`direct_upgrade_loop`, `migrate_direct_path`, `accept_connections`,
`accept_tcp_connections`), a global `candidate_attempts` map, a `PathManager`
that persists remote discovery truth, a logical `Session` that survives
transport loss with crypto-root continuity, and background reconnect/direct
upgrade/path migration tasks. V2 deletes or re-scopes each of these.

## Decision

### ConnectivityAttemptCoordinator 是唯一连接入口

所有连接必须进入 `ConnectivityAttemptCoordinator::connect()`。每次请求先做
不依赖控制面的 Stage A Direct 复用/候选探测；只有 Stage A 失败才进入下面的
Resolve 状态机：

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

- 生命周期：`Stage A Direct/reuse → Resolve → 创建 Attempt → Candidate
  coordination → Direct connect → 成功/失败 → Attempt 销毁`。任何健康且
  capability-compatible 的 ready path（包括 Relay）在进入控制面前即可复用；
  复用成功时不发送 Resolve、Offer 或 Relay reservation。
- Candidate 完全 attempt scoped：`CandidateSet` 只属于本次连接尝试。
- **禁止**：Attempt 1 的 remote_generation 影响 Attempt 2；Attempt 1 的
  remote_attempt_id 留在全局 PathManager；Presence Event 删除当前 Attempt。
- 删除 `network-nat` 的 persistent `remote_generation` / `remote_attempt_id`。

### ConnectivityAttempt 的版本与候选更新边界

`ConnectivityAttempt` 只保存完整的 128-bit `RuntimeEpoch`，不把 epoch 压缩成可排序的 `u64`。同 epoch 时按 `revision` 判 stale/update；不同 epoch 代表新的 Runtime snapshot，直接替换旧候选集。Answer 晚到时，只要 coordination channel 尚未关闭且 Direct deadline 未到，新候选仍要加入当前 race。

### PathManager 仅保留 metrics

- `ConnectionPathMetrics` 只属于已建立连接的 RTT / Jitter / Loss / Endpoint。
- `HistoricalPathMetrics` 只能作为性能提示，不能决定 Candidate 是否仍然有效。
- PathManager 不保存远端 Discovery Truth；远端候选权威来自 Resolve 返回的
  `DiscoverySnapshot`。

### ConnectionSession 与 Transport 同生命周期（可丢弃）

- `Transport Connection → Identity Auth → Noise E2EE → ConnectionSession →
  Transport Lost → ConnectionSession Destroyed`。
- 重新建立 = `New Connection → New ConnectionSessionId → New Noise Root`。
- 禁止恢复旧 Socket 的 `CryptoContext` 或跨 Transport 复用 Session/route/crypto
  root 连续性。
- Delivery 与 Transfer 的业务状态不属于 ConnectionSession；未确认消息按
  `MessageId`/业务 channel 恢复，文件按 `transfer_id` 与 `confirmed_offset`
  恢复。

### Direct First 顺序建连（4s 窗口）

- Stage A 只使用 fresh cache/configured candidates 和
  capability-compatible ready-path reuse；它不调用控制面。若已有健康 Relay
  path，物理路径 owner 也在 Stage B 之前完成复用，避免对 target-less Offer
  产生无主的控制面 ticket。
- 这是对新建/替换连接的 Resolve 权威规则的明确复用例外：已认证的当前
  transport path 由其 owner 以 `path_is_connected + capability` 判定可复用，
  不再为同一条健康连接发出另一个 Offer。远端 runtime restart 会使该认证
  transport/session 失效；一旦进入新建/替换路径，`ReadySessionIndex` 仍以
  Resolve epoch 做 `Close old → New`（`take_obsolete_closes_old_when_epoch_changed`）。
- Stage A 失败后，Stage B 在同一条 Control Connection 上完成一次权威
  `Resolve → Offer` transaction，再使用该 Resolve snapshot 建立 Attempt 和
  **Direct First 4s** 窗口。Offer 入队前保持窄 target-binding gate，但不把
  answer/direct race 锁在 gate 内。
- 4s 内任一 identity-authenticated + E2EE-ready Direct 成功 → `CONNECTED_DIRECT`。
- 4s 超时 → `DIRECT_FAILED` → `ReserveRelay` → Relay Data。Relay 不和 Direct
  并行抢跑。

Direct race 以 `(candidate_id, endpoint, generation)` 为边界；同 ID 但 endpoint 或 generation 更新时必须重新尝试，权威 snapshot 删除的未启动 candidate 必须丢弃。支持 generic WebSocket 的路由中，TCP 与 WebSocket 在同一 candidate window 内并行启动。

### 不再进行 Relay → Direct 后台升级

- 删除 `schedule_direct_upgrade` / `direct_upgrade_loop` / background direct
  probe / Relay → Direct auto migration。
- Connection 选定 Direct 或 Relay 后直到连接结束 Route 不变；Relay 断线后
  显式重新 Resolve，下一次可能直接变成 Direct。
- 未来若需性能优化，单独实现 `RouteOptimizer`，不能成为正确性依赖。

### 连接重用规则

每次新的 `connect()` 先尝试 capability-compatible 的健康 ready path 复用或
Stage A fresh Direct 探测；只有这些路径失败才 Resolve。进入 Stage B 后，
Resolve 返回的 epoch 仍用于候选/新 Attempt 的权威绑定；若索引发现旧 epoch，
必须 Close old → New ConnectivityAttempt。

## Consequences

- 没有隐藏的透明重连 / DirectUpgrade / RepairPath / RestoreRoute；Transport
  断开后业务显式重新 Resolve。
- Presence Event 无权修改 ConnectivityAttempt / CandidateSet /
  ConnectionSession；UI 提示与实际建连状态解耦。
- 大流量 Relay Data 不会与 signaling 共享 socket/queue（见
  ADR-RELAY-DATA-PLANE-V2）。

## Verification

按 Main 基线版 §40 测试矩阵的 Connection / NAT / Concurrency 组执行：Stage A
compatible reuse 的控制面零调用、Stage A 失败后的单次 Resolve → Offer、same
epoch reuse、new epoch 不复用、QUIC direct success/timeout、TCP / WebSocket /
Relay fallback、identity mismatch、同时连接多个 peer、同 peer 多 connect 合并、
stale/delayed attempt answer、同 ID candidate endpoint/generation 更新、删除未启动
candidate、TCP blackhole + WebSocket reachable，以及 Direct window 内延迟 answer
新增 QUIC candidate。
