> 最新更新时间：2026-08-19

# ADR-DISCOVERY-V2：Discovery 重构（runtime_epoch + revision、可靠发布、四态 Resolve）

## Status

Accepted for the transport-network v2 breaking refactor (2026-08-15). Companion
to ADR-TRANSPORT-NETWORK-V2; implements design doc §6-§10, §23 and Step 3.

## Context

v1 uses a per-owner Unix-ms `generation` for discovery, treats presence as the
authority for online determination, silently stores `discovery_update` with no
acknowledgement, and answers `lookup` with a binary `online *bool` including
fail-open "online=true generation=0" paths. v2 must make the server
authoritative, make discovery versioning unambiguous across runtime restarts,
and make publication reliable.

## Decision

### Presence is advisory

`Presence` 只表示「当前设备有没有有效的 Relay Control Connection Lease」：

```text
PresenceLease {
    device_id
    control_connection_id
    relay_instance_id
    last_seen
    expires_at
}
```

固定 `Heartbeat = 20s`、`Presence TTL = 60s`。Presence 禁止参与 Candidate
validity、Route selection、Connection Attempt、Session continuation。客户端
最多保存 `PresenceHintCache`，只给 UI 使用。Redis Pub/Sub 丢一个 Presence
Event 的最坏结果是 UI 显示不准确；用户真正通信前 `ResolvePeer` 立刻得到权威
状态。

### Discovery uses runtime_epoch + revision

```text
DiscoverySnapshot {
    device_id
    runtime_epoch
    revision
    transport_capabilities
    candidate_bundle
    published_at
}
```

- `runtime_epoch`：Native Runtime 每次启动随机生成一个新的 128-bit ID。
- `revision`：同 `runtime_epoch` 内严格递增；网络变化（Interface / IP / NAT
  Mapping / STUN Mapping / UDP Socket Rebind）→ 重新 gather → `revision++`
  → `DiscoveryPublish` → `DiscoveryAck`。
- **跨 epoch 不存在大小比较**：`E1/revision=500` 与 `E2/revision=1` 不可比较。
- **彻底删除**：Unix timestamp generation、跨进程 generation 单调、old
  generation > new generation 特判。

ConnectivityAttempt 保存完整的 128-bit `RuntimeEpoch` 身份。只有相同 epoch 的 `revision` 才能按大小比较：更小的是 stale，更大或相等的 revision 更新当前 snapshot；不同 epoch 直接替换 remote snapshot，不对 epoch 做数值大小判断。

Answer 到达后，只要 attempt 的 coordination channel 仍存活且尚未超过 Direct deadline，新 QUIC candidate 必须加入当前 race；候选暂时为空不是结束 Direct phase 的理由。

### runtime_epoch 与 control_connection_id 分离

WiFi 瞬断导致 Relay WSS 重连（`C1 → C2`）时 Runtime 未重启：`runtime_epoch`
保持 `E1`，`DiscoverySnapshot` 仍可发布 `E1/revision=8`。新 Control
Connection 建立后重新发布完整 Snapshot。Redis owner 使用
`control_connection_id`；协议语义使用 `runtime_epoch + revision`。CAS
ownership 与网络生命周期不再混在一起。

### Discovery publish 必须可靠

固定协议：`Native → DiscoveryPublish → Relay → Redis CAS → Persisted →
DiscoveryAck → Native`。

```text
DiscoveryAck {
    request_id
    runtime_epoch
    revision
}
```

- 只有收到 ACK，`LocalDiscoveryState = PUBLISHED`；否则按 `500ms / 1s / 2s /
  4s / 4s` 重试，**最多 5 次**；超过后 `DiscoveryState = DEGRADED`，Control
  Connection 不立即断开。
- 网络变化后的 re-gather / `revision++` / publish 是 **Native 自己的职责**；
  Dart 不再负责手动 `UploadDiscovery`。

### Resolve 成为连接唯一权威入口

`lookup` 重构为 `ResolvePeer`：

```text
ResolvePeerRequest  { request_id, target_device_id }
ResolvePeerResponse { READY | OFFLINE | NOT_READY | UNKNOWN, ... }
```

| 状态 | 含义 | 客户端行为 |
|---|---|---|
| READY | Presence + Discovery 均有效且 owner 一致 | 可以建连（唯一允许生成 ConnectivityAttempt 的状态） |
| OFFLINE | Presence 确定不存在 | 返回 `PeerOffline` |
| NOT_READY | Presence 在线，但 Discovery 尚未可靠发布 | 可短暂重试 Resolve |
| UNKNOWN | Redis / Backend 状态无法可靠判断 | 返回 `ControlUnavailable` |

**禁止再出现** `Redis 出错 → online=true generation=0` 这类 "fail-open 但
伪装成正常结果" 的状态。

## Consequences

- 服务器重新成为连接前权威；presence 与 discovery 解耦，presence 推送丢失
  不影响连接正确性。
- 跨 Runtime 重启的 Discovery 版本冲突（大小比较歧义）消失。
- 发布可靠性从"依赖下次连接重传"变为有 ACK + 有界重试 + DEGRADED 状态。

## Verification

按 Main 基线版 §40 测试矩阵的 Discovery 与 Control 组执行：同 epoch
revision++、Runtime restart → new epoch/revision=1、old epoch event delayed、
NOT_READY / OFFLINE / UNKNOWN、Discovery Publish 第一次失败、ACK 丢失、
retry 成功、Relay Control reconnect、Runtime 不重启但 Control Connection
变化。Control 组还须覆盖 heartbeat、Redis 临时不可用、Redis 出错时不返回
fail-open 假在线；并覆盖高位/低位不同的两个 RuntimeEpoch 不做数值排序、远端重启以新 epoch 替换旧 snapshot、延迟 ConnectivityAnswer 携带的新 QUIC candidate 在 Direct deadline 内继续参赛。
