> 最新更新时间：2026-08-15

# ADR-008：Direct First 顺序建连（先 Direct，超时再 Relay）

## 状态

Accepted（2026-08-15 修订：移除 500ms 并行 Relay 竞速，改为**顺序 Direct
First**，对齐《明确版》的 4s 建连窗口语义。原「Direct 立即尝试 + 500ms 后
启动 Relay lookup + 首个 ready 胜出」决策作废。）

## 背景

Direct QUIC 可能因为 UDP 被封锁、NAT 或路径失效而长时间等待。若完整等待
Direct timeout 后才查询 Relay，用户会在可用 Relay 已经存在时仍然等待数秒。

## 决策

- Direct candidate 在连接请求开始时立即尝试，**先只跑 Direct**。
- 等待 connect_window（默认 4s，`DEFAULT_CONNECT_WINDOW_MS=4000`）。
- connect_window 内任一候选完成 identity-verified QUIC 握手 → 发出
  `DIRECT_READY`，直接绑定 Direct 到当前 Session，不启动 Relay。
- connect_window 超时 → 发出 `DIRECT_FAILED`，此时才启动 Relay peer lookup。
- 单个 Direct candidate 快速失败不影响窗口内其它候选继续尝试；原「快速失败
  不终止另一条仍在尝试的路线」的精神，以「等满 connect_window 再起 Relay」
  体现。
- Relay 路线一旦启动，其 ready / 失败按 Relay 自身的 lookup 语义处理；Relay
  胜出时绑定当前 Session（Direct 尝试此时已结束，无并行清理问题）。
- 没有 Direct candidate 时立即尝试 Relay；只有单一路线时保留该路线的 8 秒
  总预算。
- 首个 ready Route 绑定到当前 Session。

## 后果

UDP 受限网络可以快速进入 Relay，正常直连仍优先使用 Direct（4s 内直接命中，
不为等待 Relay 增加握手）。相比旧的 500ms 并行竞速，Direct 拥有完整的 4s
建连窗口，减少「Direct 本来 4s 内可达、却因 Relay 500ms 先 ready 而先走了
Relay」的路径劣化；代价是彻底无法 Direct 时最多多等 4s 才进入 Relay。
顺序 Direct First 也避免了两条路线并行时的取消与 waiter 清理复杂度：Relay
只在 Direct 超时后启动，胜出路径与另一条路线不再重叠。

## 验证

native 测试覆盖：connect_window 内 Direct ready、超时后 Relay fallback、
单个 Direct candidate 快速失败仍等满窗口、无 Direct candidate 立即 Relay、
单一路线的 8s 总预算、以及 Relay 胜出后绑定当前 Session 的语义。
