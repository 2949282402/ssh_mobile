> 最新更新时间：2026-08-15

# ADR-014: Path Quality Sampling and Native Route Migration

## Status

Superseded on 2026-08-15：transport-network v2（[ADR-CONNECTION-LIFECYCLE-V2](ADR-CONNECTION-LIFECYCLE-V2.md)）
把 `PathManager` 收敛为 **metrics-only**（`ConnectionPathMetrics` /
`HistoricalPathMetrics`），并**删除 route migration**（`migrate_direct_path` /
`monitor_direct_path` / 更优候选原子替换 Connection）。v2 中 Connection 建立时
选定 Direct 或 Relay，之后直到连接结束 Route 不变；历史性能只作为提示、永远不能
决定 Candidate 是否有效，也不再驱动迁移。

## Historical note

本 ADR 记录 v1 的路径质量采样（EWMA RTT / jitter / loss）与原子路由迁移决策，
保留仅供决策历史参考。`ConnectionPathMetrics` 的采样思想在 v2 中保留给已建立
连接的性能观测；`HistoricalPathMetrics` 只作为性能提示。

## 背景

`Candidate` 已有 RTT 和 loss 字段，但运行时没有把已建立 QUIC Connection 的
真实统计接入 `PathManager`，也没有在更优候选准备好后安全切换 Connection。
仅按静态 priority 选路会掩盖高延迟、丢包和抖动路径。

## 决策

- Direct QUIC 连接由 native monitor 周期读取 `Connection::rtt()` 和
  `ConnectionStats.path`，更新 Candidate 的 EWMA RTT、jitter、loss、成功时间和
  sample count；未知质量的 Candidate 不因默认 RTT=0 获得虚假的质量优势。
- `PathManager` 使用 priority、RTT、jitter、loss 评分，并要求候选领先当前路径
  一个固定滞后阈值后才请求迁移，减少路径抖动。
- 迁移必须先对新 Candidate 建立完整 QUIC 连接并通过现有 Ed25519 + TLS exporter
  认证，再用 Session ID 和当前 Connection stable ID 原子替换 Session；旧连接只在
  新连接接管后关闭。替换失败时新连接被关闭，旧连接保持不变。
- 运行时通过已有 `RouteChangedEvent` 发布采样和迁移后的 RTT/loss；不新增或修改
  Flutter/Dart 客户端协议字段，jitter 保留在 native Candidate 质量模型中。

## 影响

已建立 Direct 连接会产生 native-only 的质量采样任务；任务在 Connection 不再是
Session 当前连接时退出。未来 Candidate 交换接入更多地址后，可以复用同一迁移边界
而无需改变 Session、Delivery 或前端 API。

## 验证

- PathManager 单元测试覆盖 RTT、jitter、loss EWMA 和带滞后的更优路径选择。
- 双 runtime QUIC 集成测试确认 Connected 后会产生 RouteChanged 质量事件。
- workspace 测试和 Clippy 使用 `--locked` 通过。
