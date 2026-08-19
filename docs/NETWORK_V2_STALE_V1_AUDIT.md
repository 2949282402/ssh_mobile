最新更新时间：2026-08-19

# Transport Network V2 文档与验证审计

## 审计范围

本记录审计当前工作树中新增的 v2 相关实现，覆盖 Rust `network-core` 与
`network-nat`、Dart native/transport、Go Relay 以及 Relay Protocol V2 的测试
入口。它是迁移期间的审计记录，不替代代码、测试、协议契约或 Accepted ADR。

## 结论

- **协议与架构文档已存在**：`protocol/RELAY_V2_CONTRACT.md`、
  `ADR-TRANSPORT-NETWORK-V2`、`ADR-DISCOVERY-V2`、
  `ADR-CONNECTION-LIFECYCLE-V2`、`ADR-BUSINESS-RECOVERY-V2` 和
  `ADR-RELAY-DATA-PLANE-V2` 分别覆盖 wire、Resolve/Discovery、连接生命周期、
  业务恢复和 Control/Data 分离；本次没有新增架构决策，因此不创建重复 ADR。
- **CI/验证入口已存在**：`.github/workflows/flutter.yml` 的
  `protocol-v2-contract`、`native-network-quality`、`relay-quality` 和
  `sdk-dart-quality` 覆盖协议 fixtures、Rust、Go Relay 与 Dart SDK。现有
  `scripts/relay_v2_contract.sh` 负责 fixtures/proto/buf 合同检查，不应被误读为
  Rust/Go 单元测试替代品；后者由对应 CI job 执行。
- **Memory 已补齐当前高成本事实**：SDK Memory 记录 command-result 去重、peer
  connect intent、CandidatePayloadV2 cache 和 Delivery attempt 边界；Backend
  Memory 记录 v2 request/attempt 校验、Resolve fail-closed、epoch 要求、数据面
  role binding 与吊销关闭。
- **本地 WSL Rust 验证已通过**：`cargo fmt --all -- --check`、
  `cargo check --workspace --locked`、workspace Clippy `-D warnings` 和
  `cargo test --workspace --locked` 均通过；其中 `network-core` 当前为 207 项。
- **本地 WSL Go 验证已通过**：Go 1.26.6、gofmt、`go test ./...`、
  `go test -race ./...`、`go vet ./...` 和 `govulncheck ./...` 均通过。
- **本地 WSL Dart 验证已通过**：Flutter 3.44.2 / Dart 3.12.2 下完成 format、
  analyze，以及 21 个 package 的串行 `flutter test --no-pub --concurrency=1`；
  Full App 当前 832 项测试也通过。
- **Network SDK/Data V2 已完成切换**：native Rust/Dart wire envelope 使用协议版本
  2，schema package 为 `network.v2`，QUIC ALPN 为 `ssh-mobile/2`，App codec 为
  `NetworkProtocolV2Codec`；Relay Bootstrap `/v1/devices/*` 与 C FFI ABI `1`
  保持独立，不因 Network Protocol V2 自动升级。
- **V2 ownership 命名已收口**：连接尝试由
  `ConnectivityAttemptCoordinator` 编排，ConnectionSession 由
  `ConnectionSessionStore` 保存，`ReadySessionIndex` 只保存可复用摘要；Peer
  lifecycle 仍由 `PeerSupervisorRegistry` 负责。Network V2 `SendMessage` /
  `DataMessage` 不再携带 per-message crypto mode，始终使用 Session E2EE。
- **关键生产队列已收口**：Runtime event mailbox 与 Transfer progress channel
  有界；WebRTC I/O event sink 也必须使用有界 Tokio channel。测试适配器可以使用
  unbounded channel，但不进入生产运行时。
- **历史文档边界已标明**：旧 ADR 和模块化迁移记录中的 v1 名称只保留决策历史；
  当前实现、README、AGENTS 与 V2 ADR 才是 Network Protocol V2 的权威说明。

## stale-v1 边界

- `docs/baseline_records.md` 保留为 `network-v1-final` 的历史冻结记录，不代表
  当前 v2 实现状态。
- `docs/architecture/RELAY_CONTROL_PLANE.md` 明确标注为 v1 控制面基线，并在
  “transport-network v2 部分取代”章节维护边界；其 v1 内容不能作为 v2 行为依据。
- `ADR-010` 仍保留 Delivery 的基础不变量，但其中关于 Session/Connection 连续
  性的 v1 语句由 `ADR-BUSINESS-RECOVERY-V2` 与
  `ADR-CONNECTION-LIFECYCLE-V2` 取代。
- `ADR-022` 仍保留 Runtime supervisor 的根取消、任务 join 与 stop 边界，但其中
  把 reconnect、direct-upgrade 或 Delivery retry 归属到旧 Session task group 的
  v1 语句由 v2 生命周期/业务恢复 ADR 取代。
- Relay Bootstrap/WebSocket V1 contract、历史 fixtures 和被 superseded 的 ADR
  仍保留，但必须显式标注为独立 Bootstrap/历史边界。Network SDK/Data V1 的
  active package、旧 codec、旧 schema 和 per-message crypto-mode compatibility
  path 已退休；它们不再作为当前 V2 的 fallback。

## 验证边界与环境记录

- PathHandshakeV2 与 Relay `DATA_ENV_CRYPTO` 的 admission 已接入真实 Rust
  dispatch gate：PairReady 后先处理 crypto/path-handshake，只有
  `complete_relay_path_admission` 完成后才设置 `relay_path_ready` 并发布 Connected；
  PathHandshake、Rust workspace 和 Relay strict 选择器均有通过证据。
- CandidatePayloadV2/cache 现在由 `RuntimeState` 持有，Stage A 会先读取 fresh
  monotonic cache/configured direct candidates，失败后才进入 Resolve→Offer；Resolve
  与 ConnectivityAnswer 会刷新 cache；过期 Stage B refresh、heartbeat 不刷新、
  epoch invalidation 和 server TTL 已有 Candidate V2 测试。
- RelayData L1 已补 PairReady Ping、30s/15s Ping-Pong liveness、single-writer
  control frames、pair 后 reservation consumption、active TTL 解耦和 upgrade
  pending revoke tracking；过期 data admission、idle natural expiry、explicit
  revoke close 和 persistent-failure fail-closed 均由 Go 测试覆盖。
- ReliableStream manager 已在 Session teardown 保留 per-peer tombstone，旧
  `(peer, opener, stream_id)` handle 不能在重连后透明复用；未实现跨路径透明迁移，
  符合 lease=lifetime 约束。
- Core Runtime 对外事件根队列已改为 count+byte bounded sender；FFI/Dart EventMux
  继续执行 control/data fairness、overflow policy 和单事件硬上限。测试专用
  `UnboundedSender` 适配器不进入生产 Runtime。
- 当前 WSL 未提供 `protoc` 或 `buf`；`bash scripts/relay_v2_contract.sh` 会明确
  跳过这两个工具的编译/lint 子检查，Relay fixture/contract 与 Go 门禁仍已执行。
- WSL workspace Flutter 默认并发会让多个 localhost MCP 测试争用回环 socket；按
  package/file 串行模式复跑后 21 个 package 全部通过。该环境差异已记录，未修改
  MCP 业务实现来掩盖测试竞争。
- 未运行真实多主机/移动设备硬件部署验收：当前证据来自 WSL 本地 Rust/Go/Dart
  测试与 committed protocol fixtures，原因是本地没有外部设备/Relay 集群 endpoint。
