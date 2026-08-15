> 最新更新时间：2026-08-15

# ADR-011：TransferSession 与 Connection 解耦

## Status

Accepted（2026-08-15 消歧：本 ADR 是唯一的 ADR-011。原先重复编号的
[ADR-030-file-resume.md](ADR-030-file-resume.md)（直连文件 checkpoint 与 Resume，
原 ADR-011-file-resume）已重编号为 ADR-030。内容不变。）

## 背景

文件传输需要在 QUIC Connection 被替换、断开或迁移后继续保留
TransferId、Manifest、逻辑 SessionId 和已确认偏移。若 TransferManager
直接保存或判断 `quinn::Connection`，Route 生命周期就会错误地决定业务传输
是否失败。

## 决策

- `network-transfer` 由 `TransferSession` 保存传输业务状态、源文件、Manifest、
  偏移、取消句柄和逻辑 SessionId 编码；它不依赖 Quinn、Relay socket 或其他
  Route handle。
- Transfer 状态统一经过 `Offering`、`WaitingApproval`、`Transferring`、
  `Paused`、`Resuming`、`Verifying`、`Completed`、`Cancelled`、`Failed`。
  可恢复的网络错误进入 `Paused`；哈希、源文件、审批、协议、权限、重试预算
  或不可恢复 IO 错误才进入 `Failed`。
- `TransferDispatcher` 是 `network-core` 的 Route adapter。它根据当前逻辑
  Session 的 Route 注入 QUIC Connection 或 Relay 发送 worker，业务 Manager
  不再读取 `Option<quinn::Connection>`。
- 恢复领取按 `PeerId + SessionId` 原子筛选。同一逻辑 Session 的 Connection
  更换可以重新领取暂停传输；显式关闭后创建的新 Session 不能领取旧传输。
- Direct QUIC 已接入该状态机和同 Session offset 恢复。Relay 文件恢复使用新的
  socket token，但加密 offer 固定携带 TransferId、Manifest Hash、File Hash 和
  Manifest 字段；接收方通过带校验的 accept 返回稳定 `.part` offset，不能把
  QUIC offset 或 Relay token 当成新的 TransferId。
- Relay socket 意外断开只清理当前 attempt handle，TransferSession 与 `.part`
  保留在 native runtime；指数退避重连成功后会重新 Offer 并领取同一逻辑
  Session 的暂停传输。已完成文件在 complete_ack 丢失后按 SHA-256 幂等确认，
  不覆盖目标文件。

## 后果

Connection 和 Route 可以独立销毁、替换或迁移，而 TransferSession 的业务
状态仍由 Manager 管理。Route 适配层可以继续扩展 Relay、Generic Transport
和 WebRTC，而不把具体连接句柄泄露到文件传输业务层。

## 状态

Accepted
