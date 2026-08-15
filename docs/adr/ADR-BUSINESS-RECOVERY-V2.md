> 最新更新时间：2026-08-15

# ADR-BUSINESS-RECOVERY-V2：业务恢复上移到传输之上

## Status

Accepted for the transport-network v2 breaking refactor (2026-08-15). Companion
to ADR-TRANSPORT-NETWORK-V2; implements design doc §19-§22 and Step 9.

## Context

v1 通过「逻辑 Session 存活 + reconnect_loop 复用同一 SessionId + ContinueExisting
crypto root 复用 + notify_generic_route_loss」对 SSH / Realtime / Delivery /
Transfer 做透明恢复。V2 的 `ConnectionSession` 与 Transport 同生命周期（见
ADR-CONNECTION-LIFECYCLE-V2），因此**连接断开后不再有旧 Session 可以恢复**；
只有真正需要连续性的业务状态（文件、可靠消息）才在上层恢复，SSH / Realtime
建立新 Session。

## Decision

### 跨连接真正保存的是 BusinessOperation

- 文件：`TransferOperation { transfer_id, peer_id, manifest_hash, total_size,
  confirmed_offset }`。连接断开 → `TransferOperation = PAUSED`，
  `ConnectionSession = DESTROYED`。
- 恢复：`Resolve → New Connection → New Noise Session → ResumeTransfer(transfer_id)
  → 协商 confirmed_offset → 继续`。
- 可靠消息：跨连接稳定的是 `MessageId` / `ChannelId` / `Delivery State`，而
  不是 Transport Connection。未 ACK 消息在连接断开后重新 Resolve → New
  Connection → 重发同一 MessageId → 对端 dedup。

### Delivery / Transfer 恢复锚定业务身份

- `DeliveryManager` / `TransferManager` 继续拥有 retry/resume（已在 v1 落在
  transport 之上），但 V2 把 ACK / dedup / 恢复周期从 `SessionId` +
  `recovery_epoch` 重新锚定到**业务身份**（`MessageId` / `transfer_id`）。
- `recovery_epoch` 语义保留（ADR-010），但不再随新 Connection 隐式递增为
  Session 级周期；它属于业务恢复周期。
- Delivery / Transfer 之间通过 business identity 领取暂停状态；新 Connection
  不再复用旧 SessionId 的索引。

### SSH 不做透明恢复

- SSH 网络断开 → `SSH Connection Closed`。Network Core 不恢复旧 TCP 字节流、
  旧 QUIC Stream、旧 crypto root。
- 重新连接时 `Resolve → New Connection → New SSH Session`。需要保持 Shell 时
  使用 `tmux / screen`。未来需要时再设计 `RemotePTYSession`。

### Realtime 不恢复旧 PeerConnection

- WebRTC 断开 → `RealtimeSession Closed`。恢复 = `Resolve → 重新 signaling →
  New PeerConnection`。不恢复旧 PeerConnection 对象。

### 业务恢复错误模型

固定四类：

```text
RecoverableTransportLoss   （可恢复传输丢失，进入重试/恢复）
OperationExpired           （业务操作超时/过期）
ResumeRejected             （对端拒绝恢复）
```

禁止把业务恢复失败全部映射为通用 `RelayError` 或 `IoError`。

## Consequences

- Transport loss 后**不执行通用透明恢复**；业务按各自语义决定是否重建
  （SSH/Realtime 重建 Session，Delivery/Transfer 按业务身份恢复）。
- Delivery / Transfer 的 ACK / dedup / epoch 契约从 Session 生命周期解耦，
  与可丢弃的 ConnectionSession 兼容。
- UI 不再被「连接恢复中」的假状态误导；每次连接断开都是明确的终态，恢复
  由业务主动发起。

## Verification

按 Main 基线版 §40 测试矩阵的 Recovery 组执行：Reliable Message 未 ACK 后断线、
新 Connection 重发、duplicate MessageId；File transfer 中断、新 Connection
Resume、checkpoint 一致；SSH 断线不恢复旧 stream；WebRTC 断线新建
PeerConnection。并验证 recovery_epoch 锚定业务身份后旧 Session 的 Pending 不会
进入新 Session。
