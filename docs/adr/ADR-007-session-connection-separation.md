> 最新更新时间：2026-08-19

# ADR-007：Session 与 Connection 生命周期分离

> **V2 状态**：本 ADR 保留早期 Session/Connection 分离决策的历史记录，已由
> Network Protocol V2 的 PeerSupervisor、PeerPathManager、PathLease 与
> ConnectionSession 生命周期契约取代。旧 `SessionManager` 命名和 v1 wire 说明
> 不再是当前实现依据。

## 背景

网络断开、Route 切换和后续 Delivery Recovery 不能因为当前 QUIC
Connection 被销毁而丢失业务会话身份。此前 Rust Core 以
`HashMap<PeerId, quinn::Connection>` 作为连接状态，无法保留跨连接状态。

## 决策

- Rust Core 由 `SessionManager` 持有每个 peer 的唯一 Session 聚合根。
- Session 分配稳定的 `SessionId`；临时 QUIC `Connection` 只作为 Session 的
  当前 transport handle。
- Connection 建立、替换和断开只更新 Session 的 `Connecting`、`Connected`、
  `Reconnecting`、`Disconnected` 或 `Failed` 状态，不删除 Session。
- 只有显式 disconnect 才将 Session 标记为 `Closed`；下一次连接请求会创建
  新的 Session ID。
- 旧 Connection 的异步收尾必须校验 stable ID，不能覆盖已经绑定的新
  Connection 或其状态。
- Delivery、Crypto 和 Transfer 状态后续挂载到 Session，不回到 transport
  map 或 Flutter 客户端状态。

## 后果

Session 可以跨 Direct/Relay 和后续 reconnect 保持身份；当前 v1 Protobuf、
FFI、Flutter API 与事件结构不变。自动重连和 Delivery Recovery 仍由后续
步骤负责，当前 SessionManager 只提供生命周期与当前 Connection 边界。

## 状态

Superseded by Network Protocol V2 lifecycle contracts.
