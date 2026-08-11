> 最新更新时间：2026-08-11

# ADR-008：Direct 与 Relay 的先 ready 竞速

## 背景

Direct QUIC 可能因为 UDP 被封锁、NAT 或路径失效而长时间等待。若完整等待
Direct timeout 后才查询 Relay，用户会在可用 Relay 已经存在时仍然等待数秒。

## 决策

- Direct candidate 在连接请求开始时立即尝试。
- 若存在可用 Relay，延迟 500ms 后启动 Relay peer lookup。
- 任一路线只有在连接/lookup 成功后才可胜出；快速失败的路线不能终止另一条
  仍在尝试的路线。
- 首个 ready Route 绑定到当前 Session；另一条尚未完成的尝试被取消，并清理
  Relay lookup waiter。
- 没有 Direct candidate 时立即尝试 Relay；只有单一路线时保留该路线的 8 秒
  总预算。

## 后果

UDP 受限网络可以快速进入 Relay，正常直连仍优先使用 Direct。当前 Relay
lookup 的 ready 语义保持 v1 不变；后续 ConnectionManager/迁移步骤可在同一
Session 上增加真正的 Relay data connection 和更细的 Route metrics。

## 状态

Accepted
