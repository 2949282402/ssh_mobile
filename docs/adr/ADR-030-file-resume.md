> 最新更新时间：2026-08-15

# ADR-030：直连文件传输的 checkpoint 与 Resume

## Status

Accepted（2026-08-15 重编号：原为 ADR-011，与
[ADR-011-transfer-session-route-dispatch.md](ADR-011-transfer-session-route-dispatch.md)
重复编号，本 ADR 改为 ADR-030 以消除歧义。内容不变。）

## 背景

文件流在 Connection 断开后不能丢弃接收端已经写入的字节。仅把 offset
字段放在协议类型中还不够：发送端必须保留源文件和 TransferId，接收端必须
保留受校验的 `.part`，完成确认丢失时还要能识别已经原子落盘的最终文件。

## 决策

- 发送端在 `TransferManager` 中保存真实 manifest、绝对源文件路径、peer、
  TransferId 和当前进度。只有 transport 类错误才把出站任务转为 `Paused`；
  审批拒绝、manifest 变化、大小/Hash 错误和用户取消仍然终止任务。
- 直连 Connection Ready 后，暂停任务按 peer 原子领取一次，重新发送相同
  manifest；接收端根据 `{transfer_id}.part` 的普通文件长度返回真实 offset，
  发送端从该 offset seek 后继续写入。
- `.part` 只能通过 `symlink_metadata` 验证为普通文件；checkpoint 超过当前
  manifest 大小时从零重建。接收端完成后重新计算 SHA-256，再原子 rename 到
  最终文件。
- 如果最终文件已经与 manifest 的大小和 Hash 完全匹配，则直接返回
  `offset == file_size` 并重发 completion ACK，覆盖“文件已落盘但 ACK 丢失”
  的恢复场景。
- 传输恢复使用同一个 TransferId 和 manifest；源文件在每次发送前重新计算
  manifest，发生变化时拒绝继续，避免把新内容拼接到旧 checkpoint。
- 本 Step 不修改 Flutter/Dart FFI 命令、事件或前端代码。Relay 文件流的
  session key、resume control 和 sequence 恢复与后续统一 Crypto/Relay
  Recovery 设计耦合，本 ADR 只落地直连 QUIC 的 checkpoint/resume 闭环。

## 后果

网络短暂中断时，直连文件不会删除已写入的 `.part`，并会在新的 QUIC
Connection 上重新协商 offset。应用重启后的持久化 checkpoint 仍需要后续
Storage/TransferState 步骤；当前 `TransferManager` 生命周期限于 native
runtime。

## 状态

Accepted（2026-08-15 起编号为 ADR-030，见上文 Status）
