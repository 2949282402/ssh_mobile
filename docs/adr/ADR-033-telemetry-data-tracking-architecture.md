> 最新更新时间：2026-08-31

# ADR-033：全端数据埋点与可观测性架构 (Telemetry & Observability Architecture)

## Status

Accepted

## 背景

为了在保障用户隐私与系统核心稳定性的前提下，实现全端（Flutter 客户端、Go Relay/Admin 服务端、React 管理后台）统一、可靠的业务行为埋点与故障诊断日志追踪，需要建立一套高可用、强一致、幂等去重且严格解耦的数据埋点与可观测性体系。

传统全量日志上传或与业务通信链路绑定的方案存在以下隐患：
1. 业务网络（QUIC/TCP/Relay）故障时导致可观测性链路同时失效，丢失关键故障诊断现场。
2. 客户端网络抖动或重试时容易造成数据重复入库或丢失。
3. 自由格式日志与散落代码中的事件名称导致数据分析口径混乱、难以治理。
4. 缺乏服务端动态下发采集策略与数据清洗生命周期机制。

## 决策

1. **可观测性平面与业务平面彻底解耦 (Decoupled Observability Plane)**：
   - Telemetry 使用独立 HTTPS 通道上报，不依赖 Rust Network Runtime 数据链路。
   - Relay 数据面与 Telemetry 采集管道零依赖、零循环引用；Telemetry 故障或数据库离线绝不影响 SSH、SFTP、Relay 或 UI 核心业务流程。
   - Analytics MySQL 与 Relay 业务数据库使用独立数据库和账号，持久化边界完全隔离。

2. **跨平台契约作为单一信任源 (Single Source of Truth Contracts)**：
   - 在 `contracts/telemetry/` 下集中定义 `events.yaml`、`error_codes.yaml` 与 `policy.schema.json`。
   - 事件命名采用标准化 `<domain>.<object>.<action>` 结构。
   - Go、TypeScript 与 Dart 统一基于契约校验事件名称、版本、参数白名单与错误码，严禁业务代码散落原始字符串。
   - 所有相关 URL 路径统一在 Go (`PathPublic...`, `PathAdmin...`)、TypeScript (`AdminApiRoutes.telemetry`)、Dart (`TelemetryEndpoints`) 中集中配置化管理。

3. **永久持久化幂等收据 (Durable Ingest Receipts)**：
   - 服务端接收批量数据时，在同一数据库事务中原子写入原始 Envelope 与永久 `telemetry_ingest_receipts` 收据记录。
   - 幂等收据不参与定时 Retention 清理，确保历史数据即使被淘汰后重传也能精准识别并返回 `already_seen`，彻底杜绝重复入库。

4. **客户端正交双状态机与非丢失存储 (Orthogonal Dual State Machine & Non-Loss Storage)**：
   - 客户端本地记录维护两个独立正交维度：
     - `syncState`: `pending` | `synced` | `rejected`
     - `logicalDeletedAt`: `null` | `timestamp`
   - 服务端成功 ACK（`accepted` 或 `already_seen`）时原子推进为 `synced + logicalDeletedAt = now`。
   - 本地受控 FIFO 淘汰机制仅允许物理删除 `synced + logicalDeletedAt != null` 的记录；`pending`（待发送）与 `rejected`（格式错误）记录永不自动物理删除，暴露缓存溢出状态（`cacheOverflow`）。
   - 客户端默认关闭 Telemetry；只有 App Shell 确认当前 Relay origin 存在有效 enrollment 后，才创建并持久化新的事件记录。Relay 未注册期间保留历史行但不新增或更新事件缓存；`uploadEnabled` 仅暂停上传调度。

5. **开发者面板诊断与一键原样重传 (Developer Diagnostics & Exact Replay)**：
   - 在客户端 Developer 调试面板中展示实时存储健康指标与缓存溢出警告。
   - 提供“一键重传”能力，保持原始 `eventId`、`occurredAt`、`sessionId`、`traceId` 重新上报，由服务端幂等收据保证去重。

6. **服务端动态策略、数据保留与诊断热缓存 (Dynamic Policy, Retention & Redis Hot Cache)**：
   - 服务端下发版本化动态策略控制上报阈值、时间间隔与特殊触发场景（`highPriorityError`、`appBackground`、`networkRecovered`、`appForegroundWithBacklog`）。
   - 数据保留（Retention）以服务端可信时间戳 `receivedAt` 为准，支持按时间与总行数双维度小批量清洗。
   - Analytics Redis 仅作为最新诊断日志的有界热缓存；当前适配器使用 Redis list，
     当 Redis 故障或未配置时自动降级查询 MySQL，不影响数据入库和聚合指标。

7. **管理后台可视化套件 (Admin Telemetry Suite)**：
   - 建设概览仪表盘（Dashboard）、事件浏览器（Event Explorer）、诊断日志流（Diagnostic Stream）及策略与数据保留配置页（Settings）。

## 后果

- **积极效果**：
  - 实现了端到端高可靠、零丢数、强幂等的数据追踪体系。
  - 统一了跨端契约治理与错误码分类标准，大幅提升故障定位效率。
  - 保护了用户隐私与系统安全，敏感凭据与未经声明的字段在客户端和服务端双重拦截。
- **注意事项**：
  - 客户端与服务端需要定期拉取并保持动态策略同步。
  - `telemetry_ingest_receipts` 表长期保留，后续如有超大规模场景需配套分段 Bloom Filter 或哈希归档升级。
