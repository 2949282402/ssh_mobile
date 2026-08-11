> 最新更新时间：2026-08-11

# ADR-009：Session 断线后的自动重连

## 背景

QUIC `Connection` 断开不应销毁仍代表业务身份的 `Session`。此前接收任务只
清理当前连接并发布 `Disconnected`，后续业务必须重新发起连接，且旧连接的
迟到收尾可能覆盖新连接状态。

## 决策

- 当前连接断开且仍是 Session 的 active Connection 时，Session 进入
  `Disconnected`，并由运行时为该 `SessionId` 启动唯一的自动重连任务。
- 重连沿用现有 Candidate 选择和 Direct/Relay 竞速，重新执行完整的 QUIC
  身份认证或 Relay lookup，不复用已失效的 Connection。
- 重连采用最多 5 次、250ms 起始退避、指数增长且上限 5 秒的有界策略；全部
  失败后发布 `Failed`，不无限后台重试。
- 重连任务以 `SessionId` 作为代际令牌。显式关闭 Session、替换为新 Session，
  或已经建立新 Connection 后，旧任务必须停止；出站连接提交和失败标记也必须
  校验同一代 Session，迟到结果不得覆盖新状态。
- 同一对端允许不同 Session 代际各自拥有任务登记，旧任务结束时只能清理自己
  的登记，避免旧任务短暂阻塞新 Session 的恢复。
- `ReconnectManager` 只负责恢复 Connection/Route；Message ACK、去重、文件
  checkpoint 与未完成业务恢复留给后续 Delivery/Recovery 与 File Resume 步骤。

## 后果

Direct QUIC 断线后可以在后台恢复，并重新参与 Direct/Relay 竞速；显式断开仍
是终止语义。当前 Relay 数据面的异常断开仍由 Relay 生命周期清理处理，Relay
自身重连与业务恢复不在本 ADR 的范围内。

## 状态

Accepted
