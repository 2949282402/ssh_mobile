> 最新更新时间：2026-08-24

# 逻辑解耦审查与实施计划

## 审查口径

本计划响应仓库当前治理要求：所有非生成生产文件超过 500 行时必须检查真实逻辑边界，500 行以下也按职责、生命周期、存储、协议和测试范围抽查。行数只触发审查，不触发机械分文件；只有可独立命名、注入、测试并拥有明确生命周期的 collaborator 才进入实施 TODO。

扫描排除测试、生成文件、vendored/third-party、build/target/node_modules 和示例工程。审查启动基线为 Client 81 个、SDK 28 个、Backend 5 个、Front 0 个超过 500 行的可执行生产源码；Front 另有一个 1902 行的全局样式资产单独审查。用户已有的 `native/network_core/crates/network-core/src/realtime.rs` 改动不纳入本阶段编辑。

新建手写生产文件必须有独立测试并达到至少 90% 文件级行覆盖率；每个 TODO 按 owning README/AGENTS 选择 focused test、owner suite 和覆盖率门禁，并单独提交。

## 实施 TODO

| ID | 当前文件 | 真实逻辑边界 | 状态 |
| --- | --- | --- | --- |
| C1 | `packages/features/feature_lan_share/lib/src/features/lan_share/services/lan_receiver_coordinator.dart` | 抽取 Relay enrollment/connect/reconnect 生命周期；Receiver owner 只保留接收端激活与 ViewModel 组装 | 已完成：`LanRelayCoordinator` 独占凭据刷新、Facade 事件订阅、显式断开和有限退避；Receiver 从 1146 行降至 636 行并只借出 Facade，Relay Owner 通过纯 Dart Port 借用外部能力 |
| C2 | `packages/features/feature_monitoring/lib/src/application/monitoring_service.dart` | 抽取采样历史/派生快照与告警判定；Service 只保留调度和远端 probe 编排 | 已完成：`MonitoringSampleStore` 独占有界历史/缓存/健康评分，`MonitoringAlertEvaluator` 独占阈值/去重/上限；Service 从 946 行降至 537 行 |
| C3 | `packages/features/feature_ai/lib/src/chat/services/llm_chat/tool_loop_controller.dart` | 抽取批次规划、并行只读执行与结果折叠策略；Controller 只保留模型 tool round 编排 | 已完成：新增 preflight、统一 result recorder 和 budget audit lifecycle collaborator；顺序/并行路径共享折叠规则，Controller 从 991 行降至约 590 行 |
| C4 | `apps/ssh_mobile_full/lib/services/background_service.dart` | 分离前台 manager 与后台 isolate/session runtime 的生命周期和协议边界 | 已完成：入口点只创建 `_BackgroundSshRuntime`；Manager 独占平台通知/权限/power，Runtime 独占 session registry/SSH/tmux/keepalive/事件订阅 |
| C5 | `apps/ssh_mobile_full/lib/services/ssh_service.dart` | 抽取 background event bridge 与 session view projection；SSH owner 保留连接/会话/命令生命周期 | 已完成：事件桥独占四类后台订阅，纯投影器独占排序和 connection overview 聚合；SSH owner 不再直接管理插件订阅字段 |
| C6 | `apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart` | 按 Peer/Transfer/Stream/Realtime typed domain 抽取命令编码和事件解码 collaborator | 已完成：窄 facade 委托 command encoder、Peer/Transfer/SSH Stream typed decoder；当前 schema 无 Realtime event tag，不创建空 Owner |
| S1 | `packages/infrastructure/ssh_mobile_network_native/lib/src/native_realtime_protocol.dart` | 分离 command encoder、event decoder 与 FFI value mapping，保留一个窄 facade | 已完成：公开静态 API 仅作 facade；命令、event envelope、Peer、Delivery/Transfer、Realtime/Stream 与边界值映射均有独立 collaborator |
| S2 | `native/network_core/crates/network-core/src/connect/connectivity_attempt.rs` | 抽取 candidate snapshot/policy 与 Stage eligibility；Coordinator 只拥有 attempt 状态机 | 已完成：candidate/cache/ranking 归 `CandidateSnapshotPolicy`，权威 Resolve 与 Relay fallback 闭门条件归 `ConnectivityStageEligibility` |
| S3 | `native/network_core/crates/network-core/src/stream.rs` | 分离 wire frame codec、stream manager 与 SSH gateway adapter | 已完成：wire/preamble/token 归 `StreamFrameCodec`，registry/lease/backpressure 归 manager，local sshd pump 与 FFI command mapping 归 `SshGatewayAdapter` |
| S4 | `native/network_core/crates/network-core/src/peer.rs` | 分离 outbound generic connector、inbound acceptor 与 receiver supervision | 已完成：generic candidate race、runtime-scope accept/admission、session-scope receiver/path-loss 分属三个具名 Owner |
| S5 | `native/network_core/crates/network-core/src/runtime.rs` | 抽取 bounded event lanes 与 projection store；RuntimeState 只保留组合和生命周期；既有 `ConnectionSessionStore` 已是独立 admission owner，保留而不重复封装 | 已完成：事件分类/字节准入/公平调度归 `BoundedEventLanes`，Session 绑定/拓扑替换/精确 stale cleanup 归 `RuntimePathProjectionStore`；Runtime 从 1891 行降至约 1598 行 |
| B1 | `relay/internal/relay/reservation.go` | 分离 reservation store、Relay Data admission、registry、flow budget 和 connection pump，并通过窄接口绑定 one-shot 授权 | 已完成：原文件从 1096 行降至当前 467 行；存储/Reserve gate、HTTP admission、one-shot registry、flow budget 与 connection pump 已分 Owner。后续安全审查使 registry/connection 超过 500 行，已按当前职责和共同不变量再次审查，见复扫记录 |

实施顺序固定为 C1→C6、S1→S5、B1。某项若在实现前的调用图/测试审查证明已有独立 Owner 且继续抽取只会增加耦合，则必须在本表记录证据后改为“保留”，不得以移动代码代替解耦。

### C1 验证记录

- `LanRelayCoordinator` 是可注入、可独立测试的状态机 Owner，不停止或释放借入的
  `NetworkFacade`/`NetworkRuntime`；它只依赖纯 Dart settings、logger、enrollment 和
  capability Port，Flutter secure storage 与具体 Runtime 均留在组合边界。
  `LanReceiverCoordinator` 只负责 LAN listener、discovery、pairing、Facade 创建和
  ViewModel 生命周期。
- Relay endpoint 观察、enrollment、credential refresh、typed retry disposition、
  bounded timer、Relay event subscription 和安全状态快照均由新 Owner 维护。
- 独立测试覆盖 endpoint 校验/撤销、能力 fail-closed、凭据刷新、有限重连、终止策略、
  外部端点替换和借用式资源释放；Receiver 集成测试继续验证 Capability 与装配边界。
  `dart test --coverage` 的文件级结果为 Relay Coordinator 90.49%、状态策略 100%、
  Port 可执行行 100%，Package format、analyze 与全部 45 个 Flutter 测试通过。
- 新 Relay Coordinator 为 573 行，已按超过 500 行规则再次审查：endpoint 事务、
  enrollment、connect/refresh/retry 与事件投影共同组成一个需要原子状态不变量的生命周期
  Owner；继续拆为互相回调的可变协作者会分裂 `_connectFuture`、显式断开和凭据刷新门禁，
  因此保留。纯 retry policy 已独立为 78 行无状态 Owner，外部依赖已收窄为 Port。

### C2 验证记录

- `MonitoringSampleStore` 是内存状态 Owner，集中维护采样、磁盘快照、错误、累计计数、
  不可变视图、可见窗口、十分钟保留/五分钟降采样以及健康评分。
- `MonitoringAlertEvaluator` 是纯告警 Owner，集中维护 CPU/内存/磁盘阈值、采样失败、
  五分钟去重与最多 80 条历史；`MonitoringService` 只保留选择、Timer、SSH probe、
  平台路由和低优先级重试编排。
- 两个新 Owner 均有独立测试，覆盖健康等级、计数速率、保留/降采样、不可变缓存、
  告警阈值、去重和历史上限；Sample Store 文件级覆盖 99.47%，Alert Evaluator 100%；
  完整 Package format、analyze 与 9 个 Flutter 测试通过，Module 集成测试继续验证
  显式启动和资源释放。
- 为使两个内存 Owner 在 Dart VM 独立验证，`monitoring_models.dart` 去除了仅用于
  字符串列表等值比较的 Flutter foundation 依赖，替换为局部值比较；没有改变公开模型
  或 JSON/等值语义。

### C3 验证记录

- `_ToolCallPreflight` 独占可见性与计划步骤门禁，确保隐藏工具在进入预算、审批、
  cache、loop guard 或执行前失败；`_ToolBudgetAuditCoordinator` 独占自动扩展、人工确认、
  模型安全审计和剩余调用封禁写回。
- `_ToolResultRecorder` 成为顺序与并行只读批次共同的 provider message、system hint、
  ledger 和 trace 折叠 Owner，同时保留顺序 cache-hit 的既有 ledger 语义。
- App 集成测试覆盖并行批次/串行回退、cache/loop guard、隐藏工具、计划门禁、预算审计、
  审批拒绝/目标漂移和 post-tool review，未改变远端审批或取消边界。

### C4 验证记录

- `BackgroundServiceManager` 仍是 UI isolate 的平台前台服务、通知权限、power lock 和
  电池优化 Owner；它不持有 SSH client、shell、session registry 或 keepalive Timer。
- `sshBackgroundServiceEntryPoint` 现在只创建并启动 `_BackgroundSshRuntime`；Runtime
  实例独占后台 isolate 的所有 session、事件订阅、tmux 命令、keepalive 和关闭顺序，
  不调用 UI isolate 的权限或 power MethodChannel。
- focused analyze 与 background service 测试验证 secret payload 清理以及 tmux/plain SSH
  的断线决策；入口点仍保留 `vm:entry-point`，平台配置回调签名未变化。

### C5 验证记录

- `_SshBackgroundEventBridge` 集中拥有 `sshStateChanged`、`sshDataReceived`、
  `sshOverviewUpdated` 和 `sshLogReceived` 四类插件订阅，重复启动先撤销旧订阅，释放后
  订阅计数归零；`SshService` 只接收类型化回调并维护 SSH session 生命周期。
- `_SshSessionProjection` 是无副作用投影 Owner，集中排序 session、按 connection 聚合
  窗口数与状态优先级，并返回不可变列表；本地运行时与后台 overview 更新仍保持原边界。
- focused analyze、日志桥、service contract 和 background runtime 测试全部通过，未改变
  SSH owner、history write queue 或借用式 core session pool 的释放顺序。

### C6 验证记录

- `_NetworkCommandEncoder` 独占所有 V2 command payload、信封和 SSH stream handle 编码；
  Peer/Route/Relay/Presence、Transfer 与 SSH Stream 事件分别由三个 typed decoder 映射，
  `NetworkProtocolV2Codec` 只保留公开 facade、event envelope 和 command result 适配。
- `network_protocol.proto` 当前没有 Realtime media 事件 tag；Realtime 仍由独立 native
  realtime protocol 管理，因此不创建无行为的 decoder，也不把两套协议强行耦合。
- codec analyze 无问题；16 个固定字节/畸形输入测试与 7 个 transport contract/integration
  测试通过，证明字段 tag、fail-closed handle 校验和 native runtime 行为未变化。

### S1 验证记录

- `NativeNetworkProtocol` 保留原有 17 个 command builder、`decodeEvent` 与
  `protocolVersion` 静态入口，但所有实现委托给内部 collaborator，对调用方和 FFI ABI
  没有变化。
- `_NativeProtocolCommandEncoder` 独占有界命令校验、payload 和 V2 envelope；event
  envelope 分派与 Peer/环境、Delivery/Transfer、Realtime/SSH Stream typed mapping 分离，
  `_NativeProtocolValueMapper` 集中 identifier、payload、stream handle 和 error 边界映射。
- 每个实现 collaborator 均低于 500 行；package analyze 无问题，24 个 package 测试通过，
  覆盖 ABI lifecycle、全部公开 command family、event matrix、畸形输入与 unknown tag。

### S2 验证记录

- `CandidateSnapshotPolicy` 独占 RuntimeEpoch 转换、Discovery snapshot 解码、candidate
  capability 过滤、remote cache 投影、Stage A target set 和确定性排序；它不推进状态机，
  也不创建 transport/session。
- `ConnectivityStageEligibility` 独占权威 Resolve 状态映射以及 Stage C 的 READY snapshot、
  RelayData、Required E2EE、requested capability 和总 deadline 闭门判定；configured endpoint
  不能把 OFFLINE/NOT_READY/UNKNOWN 提升为 READY。
- `ConnectivityAttemptCoordinator` 继续拥有 bounded Stage A→B→C 执行、Session cleanup、
  route attachment 和阶段可观察状态；`cargo check` 与 63 个 connectivity attempt 独立测试
  通过，包括 candidate/cache、epoch/revision、负向 Relay gate 和取消/超时清理。

### S3 验证记录

- `StreamFrameCodec` 是无状态 wire Owner，集中 generic open/bytes/close frame、QUIC
  preamble、稳定 opener identity 和 Relay token；兼容自由函数只作 crate 内窄 facade。
- `ReliableStreamManager` 保持 logical stream registry、sequence、bounded buffer/wakeup、
  `PathLease`、tombstone 与 hard/normal close Owner；它不解释 SSH command 或连接 local sshd。
- `SshGatewayAdapter` 独占 FFI StreamHandle/command 校验和受 supervisor 管理的 local sshd
  双向 pump；不含 SSH 协议实现，子 pump 仍在父 runtime task 内 join。
- `cargo check`、clippy `-D warnings`、27 个模块测试和 40 个跨模块 stream/Relay/QUIC/
  gateway 测试通过，覆盖双向同号 handle、背压、lease、path loss 和 tombstone。

### S4 验证记录

- `OutboundGenericConnector` 独占 TCP/WebSocket candidate race、authentication、route IO
  启动和 requested capability 复核；它不监听端口，也不负责最终 path-loss cleanup。
- `InboundConnectionAcceptor` 独占 runtime-scope QUIC/TCP accept loop、瞬态错误退避、
  handshake 和被动 authenticated admission；每个 handshake 仍注册到 root supervisor。
- `ConnectionReceiverSupervisor` 独占 session-scope bidi/channel/generic receiver、关闭 guard、
  Relay/direct 精确 route teardown 与最后物理路径丢失后的 Session/task 清理；跨模块调用现在
  显式指向该 Owner。
- `cargo check`、格式、clippy `-D warnings` 和 44 个 peer 独立测试通过，覆盖 candidate
  race、TCP/WS、inbound admission、receiver stop、Session replacement 和 runtime stop join。

### S5 验证记录

- `BoundedEventLanes` 独占 Control/Data 分类、计数和字节双重准入、每事件上限、八个
  Control 后的 Data 公平调度以及成对 endpoint 构造；`EventSender`/`EventReceiver` 只执行
  endpoint 行为，Runtime 不再解释 lane policy。
- `RuntimePathProjectionStore` 独占 Peer/Session 非 owning projection、同 topology 替换、
  alive 查询、精确 handle 清理和 Peer/topology 移除；`PeerPathManager` 仍是唯一 carrier
  owner，`RuntimeState` 不再直接读写 projection `HashMap`。
- `ConnectionSessionStore` 在实施前审查中已证明独占 admission/security storage，继续抽取
  会复制 owner，因此按保留证据不创建 wrapper；事件 lane 与 projection store 各有独立
  测试文件，另由 Runtime 边界测试验证 Session replacement 与 carrier 非 owning 语义。
- `cargo check`、格式、clippy `-D warnings`、4 个新 Owner 独立测试、11 个 Runtime 边界
  测试及完整 `network-core` 545 个测试通过。

### B1 验证记录

- `reservation.go` 只保留 Reservation 数据模型、Resolve→Offer→Reserve 有界一次性
  gate、精确 gate expiry index、lifetime clamp/hard expiry 以及 memory/Redis 的
  create/get/delete/renew；HTTP、WebSocket、pair map 和 socket budget 不再进入该 owner。
- `relayDataAdmission` 在 WebSocket upgrade 前一次性绑定 authenticated device、reservation
  role 与 role-specific token；首个 `RelayDataConnect` 再次校验同一不可变绑定。registry 的
  `admitEndpoint` 独占 one-shot role slot、PairReady 发布和 consumed 防重放。
- connection pump 只依赖 `reservationLeaseStore` 的 delete/renew 与 `relayDataPairOwner` 的
  admit/release/forward，不能访问完整 Cache、presence、enrollment、admin state 或 registry revoke
  索引；`relayDataFlowBudget` 独占出站积压 reservation/release 与入站速率窗口，socket
  owner 只执行非阻塞 channel handoff、读写、Ping/Pong 与关闭冲刷。
- admission、connection、flow budget 与 registry 各有独立测试，覆盖 role/token、
  one-shot 配对、同角色重试、PairReady enqueue/实际写入 barrier、限流、吊销、到期、
  有界 drain/Close 和共享 reservation TTL 删除后的受控重试。Stage 3 Backend 审查继续
  通过 owner Go suite、race/vet、coverage 与 Relay V2 contract gate 验证该解耦边界。

## 实施后复扫

- 按同一排除规则复扫当前树，超过 500 行的可执行生产源码为 Client 83 个、SDK 28 个、
  Backend 7 个、Front 0 个；Backend 的 2732 行 `relay_v2.pb.go` 是生成物，不进入逻辑拆分。
  所有当前路径均能回溯到上方 TODO 或完整处置清单；实施后跨线的大文件如下补充审查。
- `packages/features/feature_ai/lib/src/chat/services/llm_chat/tool_loop_helpers.dart`（832 行）
  是 `part` 实现容器，不是新增的全能 Service：其中
  result recorder、preflight 和 budget audit 是三个独立 collaborator；并行只读批次、
  Plan snapshot 与 post-tool review 是无独立可变资源的 Controller extension。它们已按
  状态与安全门禁解耦，继续拆文件只改变物理位置，不产生新的生命周期或依赖边界，保留。
- `packages/features/feature_lan_share/lib/src/features/lan_share/services/lan_relay_coordinator.dart`
  （573 行）已在 C1 中复审并保留为单一原子 Relay 生命周期
  Owner；纯 retry policy 和所有外部能力 Port 已拆出，剩余可变状态不能在不分裂连接、
  显式断开与 credential refresh 门禁的情况下继续抽取。
- `front/src/styles.css`（1902 行）是非可执行的设计 token、共享 BEM primitives、页面样式
  与响应式规则 Owner。React 页面/API/query 逻辑均已按模块分离，选择器已有组件/页面命名
  边界；仅拆 stylesheet 不会隔离运行时状态或依赖，改为 CSS Modules 也不解决本阶段发现的
  逻辑耦合，因此记录审查后保留。
- Backend 当前 7 个大文件均已做调用图、锁/状态和依赖面复审：
  - `hub.go`（1090 行）是 Control peer/lease 的唯一生命周期 Owner；staged activation、
    authoritative presence claim、exact-connection replacement、socket pump 和有界 queue
    共同维护“只有当前已激活连接可路由”的不变量。复用的精确可删除 expiry index 已把
    attempt/gate 过期顺序与表扫描解耦，Offer 锁内热路径保持 O(log n)；Resolve、presence
    sweep、hint fan-out 与 Discovery limiter 已在独立文件/协作者中，继续移动 pump 方法
    不会产生新 Owner。
  - `control_v2.go`（908 行）是无独立存储资源的 protobuf dispatch/validation facade，
    可变连接、attempt、Resolve ticket 和 reservation 状态均由 Hub/Store 拥有；按消息类型
    分文件只会拆散同一 request/attempt/ProtocolError contract，不形成生命周期隔离。
    大 Offer 的编码/分配已移到 Hub mutex 之外，锁内只复核精确连接、登记索引并入队。
  - `relay_data_registry.go`（724 行）是 one-shot pair 状态机 Owner；upgrade lease、role slot、
    pending/active 计数、consumed 防重放、same-role replacement、revoke 与 shutdown 索引必须
    在同一 mutex transaction 中变化。帧编码/大分配已在进入 mutex 前完成；HTTP admission、
    flow budget 和 socket pump 已拆出。
  - `redis_cache.go`（654 行）是一个 `Cache` adapter，集中维护 key namespace、Lua CAS/
    capacity transaction、TTL 与 event subscription，并统一施加不可覆盖的 socket/pool
    bounds；按方法族搬文件不会减少依赖或创建不同生命周期。
  - `relay_data_connection.go`（661 行）是单个 RelayData endpoint 的 pump/liveness Owner；
    activation、PairReady actual-write barrier、terminal writer gate、FIFO、Ping/Pong、
    reservation lease touch 与 bounded drain 共用同一 socket/done 生命周期。pair map 和
    流量策略已分别交给 registry 与 `relayDataFlowBudget`，剩余拆分只是物理移动。
  - `mysql_store.go`（611 行）是一个 `Storage` adapter，enrollment counter、device-row lock、
    monotonic generation、revocation tombstone 与 delete 必须共享事务/deadlock retry 规则；
    prune lifecycle 也由该 adapter 创建并关闭，继续拆分会复制数据库 Owner。
  - `cache.go`（536 行）是 memory `Cache` adapter 与其 capability contract；proof nonce
    bucket 和 earliest-expiry heap 必须在同一 `deviceMu` transaction 中变化，presence、
    discovery、reservation 与 admin session 则共享同一个 process-local cache lifecycle。
    Redis 已由独立 adapter 实现；把方法族移动到别的文件不会产生新的资源 Owner。

## 500 行以下抽查

- Front：最大可执行生产文件 `devices-page.tsx` 为 241 行；页面、UI kit、API client、schema 和 query hooks 已分 Owner，无新增 TODO；全局样式资产见实施后复扫。
- Client：抽查 `system_admin_service.dart`（491）、`mcp_tool_handler.dart`（483）、`llm_chat_service.dart`（470）和 `app_runtime.dart`（428）；分别是单一命令服务、MCP handler、LLM facade 和 App 生命周期 owner，保留。
- SDK：抽查 `network-transport/src/lib.rs`（249）、WebRTC `peer.rs`（424）与 `driver.rs`（283）；公共 transport facade、Peer 与 driver owner 已分离，保留。
- Backend：抽查 `v2/codec.go`（457）、`config.go`（469）、`server.go`（329）、
  `reservation.go`（467）与 `relay_data_admission.go`（223）；wire codec、配置、组合/
  总生命周期、reservation store 与 HTTP admission 已分 Owner，保留。

## 完整超过 500 行处置清单

### client

| 行数 | 文件 | 处置 |
| ---: | --- | --- |
| 1146 | `packages/features/feature_lan_share/lib/src/features/lan_share/services/lan_receiver_coordinator.dart` | TODO-C1 |
| 1124 | `apps/ssh_mobile_full/lib/services/app_strings.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 1039 | `apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart` | TODO-C6 |
| 1016 | `packages/features/feature_ai/lib/src/chat/views/llm_chat_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 991 | `packages/features/feature_ai/lib/src/chat/services/llm_chat/tool_loop_controller.dart` | TODO-C3 |
| 988 | `packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_chat_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 979 | `apps/ssh_mobile_full/lib/services/ssh_service.dart` | TODO-C5 |
| 979 | `packages/features/feature_lan_share/lib/src/features/lan_share/viewmodels/lan_share_viewmodel.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 978 | `apps/ssh_mobile_full/lib/services/background_service.dart` | TODO-C4 |
| 976 | `packages/features/feature_lan_share/lib/src/services/lan_share/lan_transfer_service.dart` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 975 | `packages/features/feature_lan_share/lib/src/services/lan_share/lan_security_service.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 963 | `apps/ssh_mobile_full/lib/services/sftp/sftp_service_io.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 961 | `packages/features/feature_ai/lib/src/agent/multi_agent_coordinator.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 959 | `packages/features/feature_system_admin/lib/src/presentation/views/system_admin_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 946 | `packages/features/feature_monitoring/lib/src/application/monitoring_service.dart` | TODO-C2 |
| 931 | `packages/features/feature_lan_share/lib/src/services/lan_share/lan_web_share_server.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 923 | `packages/features/feature_lan_share/lib/src/services/lan_share/lan_discovery_service.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 908 | `packages/features/feature_system_admin/lib/src/presentation/views/users_tab.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 904 | `packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_share_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 903 | `packages/features/feature_lan_share/lib/src/features/lan_share/views/widgets/lan_share_dialogs.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 899 | `packages/features/feature_ai/lib/src/chat/views/widgets/llm_settings_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 894 | `apps/ssh_mobile_full/lib/services/ai_storage/ai_settings_ops.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 892 | `apps/ssh_mobile_full/lib/services/app_settings.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 861 | `packages/features/feature_ai/lib/src/chat/views/widgets/llm_settings_widgets.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 854 | `packages/features/feature_lan_share/lib/src/services/lan_share/lan_transfer_client.dart` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 820 | `apps/ssh_mobile_full/lib/features/home/views/home_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 815 | `packages/features/feature_ai/lib/src/chat/pages/agent_trace_debug_page.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 806 | `packages/features/feature_terminal/lib/src/presentation/widgets/terminal_windows_content.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 802 | `packages/features/feature_ai/lib/src/llm/provider/openai_chat_provider.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 787 | `packages/features/feature_system_admin/lib/src/presentation/views/monitor_config.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 786 | `packages/features/feature_system_admin/lib/src/presentation/views/details_views.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 785 | `packages/features/feature_sftp/lib/src/presentation/sftp_file_viewer_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 782 | `packages/features/feature_playbook/lib/src/application/playbook_service.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 767 | `packages/features/feature_ai/lib/src/tools/ai_tool_approval.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 755 | `apps/ssh_mobile_full/lib/services/ai_storage_adapter.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 747 | `packages/features/feature_terminal/lib/src/presentation/widgets/terminal_custom_keyboard.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 735 | `packages/features/feature_terminal/lib/src/presentation/terminal_shortcut_panel.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 730 | `packages/features/feature_ai/lib/src/chat/services/llm_chat/llm_stream_handler.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 729 | `packages/features/feature_ai/lib/src/chat/views/widgets/prompt_customizer_dialog.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 728 | `apps/ssh_mobile_full/lib/services/client_system_tool_service.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 715 | `packages/features/feature_ai/lib/src/chat/views/widgets/ai_strings.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 708 | `packages/features/feature_ai/lib/src/domain/ai_ports.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 707 | `apps/ssh_mobile_full/lib/app/system_admin_feature_adapters.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 706 | `apps/ssh_mobile_full/lib/features/home/views/widgets/server_connection_widgets.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 702 | `packages/features/feature_terminal/lib/src/presentation/terminal_history_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 699 | `packages/features/feature_system_admin/lib/src/presentation/views/system_admin_server_pane.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 697 | `apps/ssh_mobile_full/lib/app/app_runtime_factory.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 681 | `packages/features/feature_mcp/lib/src/application/mcp_server_controller.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 679 | `packages/features/feature_playbook/lib/src/features/playbook/views/widgets/execution_dashboard.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 674 | `packages/features/feature_ai/lib/src/chat/services/llm_chat/llm_chat_types.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 667 | `apps/ssh_mobile_full/lib/app/sftp_feature_adapters.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 654 | `packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_preview_viewer_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 645 | `packages/features/feature_ai/lib/src/chat/views/widgets/message_todo_panel.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 645 | `packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_share_settings_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 639 | `packages/features/feature_ai/lib/src/chat/views/widgets/chat_slash_commands.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 635 | `packages/features/feature_webview/lib/src/services/client_webview_service.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 634 | `packages/features/feature_ai/lib/src/tools/ai_tool_service.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 630 | `packages/features/feature_ai/lib/src/tools/ai_tool_types.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 628 | `packages/features/feature_ai/lib/src/chat/viewmodels/ai_chat_viewmodel_message_actions.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 621 | `packages/features/feature_ai/lib/src/llm/provider/anthropic_messages_provider.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 613 | `packages/features/feature_ai/lib/src/tools/server_tools.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 604 | `packages/features/feature_terminal/lib/src/domain/terminal_keyboard_models.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 596 | `packages/features/feature_terminal/lib/src/presentation/terminal_view_area.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 591 | `packages/features/feature_system_admin/lib/src/presentation/views/services_tab.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 584 | `apps/ssh_mobile_full/lib/app/ssh_mobile_app.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 578 | `packages/features/feature_mcp/lib/src/features/mcp_console/views/mcp_console_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 567 | `packages/features/feature_webview/lib/src/services/client_webview/client_webview_ops.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 566 | `packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_pairing_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 565 | `packages/features/feature_sftp/lib/src/presentation/sftp_entry_list.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 564 | `packages/features/feature_ai/lib/src/llm/provider/openai_responses_provider.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 561 | `packages/features/feature_terminal/lib/src/presentation/terminal_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 557 | `packages/features/feature_sftp/lib/src/presentation/sftp_server_pane.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 555 | `packages/features/feature_terminal/lib/src/application/terminal_session_viewmodel.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 548 | `packages/features/feature_system_admin/lib/src/presentation/viewmodels/system_admin_viewmodel.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 543 | `packages/features/feature_sftp/lib/src/presentation/widgets/sftp_file_preview_renderers.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 534 | `packages/features/feature_terminal/lib/src/presentation/terminal_copy_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 533 | `packages/features/feature_ai/lib/src/tools/tools/client_tools_schemas.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 525 | `apps/ssh_mobile_full/lib/app/ai_external_capability_adapters.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 518 | `packages/features/feature_developer/lib/src/presentation/developer_panel_screen.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |
| 516 | `packages/features/feature_monitoring/lib/src/domain/server_status_probe.dart` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 512 | `packages/features/feature_ai/lib/src/chat/views/widgets/chat_composer.dart` | 保留：纯展示/组件组合，无资源或业务 Owner 转移 |

### sdk

| 行数 | 文件 | 处置 |
| ---: | --- | --- |
| 2591 | `native/network_core/crates/network-core/src/peer.rs` | TODO-S4 |
| 2567 | `packages/infrastructure/ssh_mobile_network_native/lib/src/native_realtime_protocol.dart` | TODO-S1 |
| 2044 | `native/network_core/crates/network-core/src/connect/connectivity_attempt.rs` | TODO-S2 |
| 2034 | `native/network_core/crates/network-core/src/crypto_handshake.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 1909 | `native/network_core/crates/network-core/src/stream.rs` | TODO-S3 |
| 1891 | `native/network_core/crates/network-core/src/runtime.rs` | TODO-S5 |
| 1684 | `native/network_core/crates/network-core/src/delivery.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 1571 | `native/network_core/crates/network-core/src/connect/path.rs` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 1300 | `native/network_core/crates/network-relay/src/v2/control_client.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 1248 | `native/network_core/crates/network-core/src/realtime.rs` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 1227 | `native/network_core/crates/network-core/src/connect/peer_supervisor.rs` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 1118 | `native/network_core/crates/network-core/src/relay_transfer.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 975 | `native/network_core/crates/network-core/src/channel.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 941 | `native/network_core/crates/network-core/src/relay_data.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 935 | `native/network_core/crates/network-core/src/commands.rs` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 916 | `native/network_core/crates/network-core/src/transfer_operations.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 914 | `native/network_core/crates/network-protocol/src/lib.rs` | 保留：契约/模型/本地化数据 Owner 单一 |
| 692 | `native/network_core/crates/network-core/src/crypto.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 681 | `native/network_core/crates/network-core/src/connection.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 673 | `native/network_core/crates/network-nat/src/candidate_v2.rs` | 保留：契约/模型/本地化数据 Owner 单一 |
| 641 | `native/network_core/crates/network-core/src/relay_control.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 639 | `native/network_core/crates/network-ffi/src/lib.rs` | 保留：符号与依赖审查显示单一 Feature/Service Owner |
| 639 | `native/network_core/crates/network-relay/src/v2/data_client.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 593 | `native/network_core/crates/network-relay/src/v2/proto.rs` | 保留：单一安全/交付/传输协议 Owner，拆分会切断共同不变量 |
| 589 | `native/network_core/crates/network-core/src/events.rs` | 保留：契约/模型/本地化数据 Owner 单一 |
| 586 | `packages/infrastructure/network_sdk/lib/src/network_v2.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 567 | `packages/infrastructure/network_sdk/lib/src/network_http_clients.dart` | 保留：契约/模型/本地化数据 Owner 单一 |
| 548 | `packages/infrastructure/network_sdk/lib/src/network_models.dart` | 保留：契约/模型/本地化数据 Owner 单一 |

### backend

| 行数 | 文件 | 处置 |
| ---: | --- | --- |
| 1090 | `relay/internal/relay/hub.go` | 保留：Control peer/lease staged lifecycle Owner；精确 expiry index、reservation gate、Resolve/sweep/hint/limiter 已解耦 |
| 908 | `relay/internal/relay/control_v2.go` | 保留：无独立资源的 v2 dispatch/validation facade；大 Offer 锁外编码，状态归 Hub/Store |
| 724 | `relay/internal/relay/relay_data_registry.go` | 保留：one-shot pair/revoke-forward 线性化的单 mutex transaction Owner；锁外编码，admission/pump/flow 已解耦 |
| 654 | `relay/internal/relay/redis_cache.go` | 保留：单一 Cache/key/Lua/TTL/event adapter 与统一连接安全边界 |
| 661 | `relay/internal/relay/relay_data_connection.go` | 保留：单 endpoint socket/pump/liveness/terminal writer/drain Owner；registry/flow 已解耦 |
| 611 | `relay/internal/relay/mysql_store.go` | 保留：单一 Storage transaction/prune lifecycle Owner |
| 536 | `relay/internal/relay/cache.go` | 保留：memory Cache contract/adapter；nonce map+expiry heap 共享原子索引，外部 Redis adapter 已分离 |

### front

| 行数 | 文件 | 处置 |
| ---: | --- | --- |
| 1902 | `front/src/styles.css` | 保留：非可执行样式 Owner；BEM/页面选择器已分域，拆文件不产生逻辑或生命周期边界 |
| — | — | 可执行生产文件最大 241 行；抽查页面、UI kit、API client 后无跨 Owner 解耦项 |
