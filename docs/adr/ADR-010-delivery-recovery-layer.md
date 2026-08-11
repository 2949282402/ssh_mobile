> 最新更新时间：2026-08-11

# ADR-010：跨 Connection 的 Delivery/Recovery Layer

## 背景

QUIC/Relay 的 transport ACK 只能说明当前连接完成了传输，不能说明远端业务
已经处理消息。Connection 断开后，`SentUnacked`、排队消息和重复到达的业务
消息需要独立于 transport 保存和判断；否则重连只能恢复“路”，不能恢复业务
状态。

## 决策

- 在 `network-core` 增加不依赖 Quinn、Relay 或其他具体 Transport 的
  `DeliveryManager`。它保存逻辑 payload、MessageId、Session/Channel、独立
  Sequence、DeliveryState、重试预算和 Recovery Epoch。
- MessageId 使用 128-bit 随机值；同一 `Session + Channel` 的 Sequence 单调
  分配，Recovery 或 Connection 切换不会重置序号。
- 支持 `BestEffort`、`LatestState`、`Acked`、`AckedDeduplicated`、
  `SessionBoundOrdered` 和 `ResumableTransfer` 策略。LatestState 只替换同一
  Session/Channel 的旧状态，其余可靠消息受消息数、payload 字节数和总 Pending
  字节数上限约束。
- ACK 必须同时匹配 Session、MessageId 和当前 Recovery Epoch；旧连接迟到的
  ACK 返回 `StaleEpoch`，不能删除新恢复周期的 Pending。
- 接收端去重窗口按 `Session + Channel + MessageId` 维护，拥有 TTL 和最大条目
  数；更高 Recovery Epoch 的同一 MessageId 只更新 ACK 绑定，较低 epoch 被拒绝，
  重复消息只重新 ACK，不重复执行。
- RetryPolicy 使用最大尝试次数、指数退避、TTL 和最大重试字节预算；过期或
  耗尽预算的消息不再无限后台重试。
- Connection Ready 会为对应真实 `SessionId` 创建新的 Recovery Snapshot，
  逐条领取 Pending 消息并通过统一 Channel adapter 重新编码到当前 QUIC
  单向 stream 或 Relay opaque control；ACK 超时由 Session 级 retry worker
  继续扫描。Pending 保存逻辑 payload，不保存旧连接上的 Ciphertext。
- native v1 协议现在包含 `SendMessage`、`AcknowledgeMessage`、`DataMessage`
  和 `DeliveryAck`；Flutter/Dart 公共 API 仍不直接暴露 Quinn、Relay 或
  Rust pointer，后续 FFI API Step 再把这些能力映射为 Session/Channel 语义。
  File Resume 的 `.part`、checkpoint 和 TransferId 恢复仍在后续 Step 单独接入。

## 后果

应用层可以在 Connection 重建后区分 ACK、重试、过期和重复消息，并保留跨路由
切换的顺序语义；真实 SessionId 变化时旧 Session 的 Pending 不会进入新 Session。
QUIC 与 Relay 都可承载相同的 DataMessage/DeliveryAck，Relay 只转发 opaque
payload。当前已有文件流仍使用自己的 manifest/完成 ACK，尚未把文件 chunk
迁移为通用 Channel；该迁移留给 File Resume 步骤。

## 状态

Accepted
