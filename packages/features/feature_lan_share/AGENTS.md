最新更新时间：2026-08-26

# LAN Share Package Guidelines

- 当前开发阶段采用破坏性 `LAN Control Protocol V2` 契约：不迁移旧 pairing
  schema、不保留旧 Secure Storage 兼容分支、不提供 V1/V2 双栈、deprecated
  wrapper 或旧文件协议 fallback。`schemaVersion != current` 时清理旧 LAN
  pairing/trust 状态并要求重新配对。
- `LAN Control Protocol V2` 与 Native `Network Protocol V2` 是两个独立版本域。
  LAN Control 只负责 discovery、pairing、capabilities、control HTTP 及文本/剪贴板
  控制面；Native Network V2 负责 peer registry、session、Direct/Relay 数据面、
  E2EE、文件传输和 Realtime。为 LAN 重构不得把 Native Network V2 升为 V3。
- Package 不得导入 SSH、其他 Feature 实现或 App 的 `/src/`；跨边界能力必须
  通过 `LanShare*Port` 注入。
- 网络客户端契约统一来自 `network_sdk`；Feature 只消费 `NetworkFacade`，不得
  自行创建 Socket、FFI、HTTP client、native handle 或第二套传输实现。
  `LanShareNetworkAccessPort` 只允许 borrow AppRuntime-owned `NetworkFacade`，
  不接受 runtime configuration 参数。
  `BootstrapClient` 和 `NetworkCommandGateway` 只能由 App Shell adapter 注入；
  网络结果、Session、Event 和 Facade 类型必须直接从 `network_sdk` 导入，
  不得恢复本地模型桥接。
- Network V2 binary transfer lifecycle event（Progress / Completed / Failed）
  必须携带 authoritative peer identity（`peerId`）；missing 或 mismatch peerId 必须 fail-closed，
  严禁仅凭 `transferId` 单标识应用传输状态或采纳沙箱文件。
- `LanShareModule` 是 `lan_share.db`、Repository、Receiver 和 Route Service
  的 Owner；Route Scope 只负责 ViewModel 生命周期。
- Receiver 只创建/释放 LAN listener、discovery、配对资源和借给 Relay 的
  Feature 资源，借用 AppRuntime 创建的共享 `NetworkFacade`；不得 start/stop/
  dispose/reconfigure App Scope 的 Facade、NetworkRuntime 或 native handle。
  所有 deactivation、close 与 initialization failure 清理统一执行 detach/release 借用语义。
  `LanRelayCoordinator` 独占 endpoint 观察、enrollment、refresh、Relay 事件订阅
  和有限重连 Timer，只能依赖 `LanRelay*Port`，且不得停止或释放借入的 Facade/Runtime。
- Trust、Discovery、Reachability、Route Availability 和 Relay Enrollment/Authorization
  必须独立建模。`isTrusted`、`isOnline` 或 Relay 连接状态不得互相推导；Discovery
  endpoint 与 runtime-scoped native port 不得写入持久 Trust Record。
- `LanPeerTrustRecord` 必须一次性包含证书指纹、双向 access token、32 字节
  X25519 public key、32 字节 Network Identity public key、origin 和明确的
  `localDirect`/`relay` authorization。Local PIN trust 默认 `localDirect=true,
  relay=false`；Relay enrollment 不得自动授予 peer Relay authorization。
- `LanNativePeerRegistry` 是唯一把 Trust Record 同步到 `NetworkFacade.registerPeer`
  以及把显式 unpair 同步到 `removePeer` 的 Owner。LAN 离线、Discovery timeout、
  Relay disconnect、route change 或 Feature deactivate 只能失效动态 endpoint，
  不得删除 Trust；`removePeer` 仅由显式 trust revoke/unpair 触发。
- App peer ↔ App peer 间二进制 image/video/audio/file 统一走 Native Network V2 Transfer；不得保留
  `POST /api/lan/upload`、HTTP binary fallback 或第二套目录/多文件协议。当前 V2
  transfer contract 只接受 regular file，directory/multi-file 必须明确拒绝。
  浏览器 WebShare 接入（Browser WebShare ingress）：由于浏览器环境限制无法运行 Native Network V2，
  使用隔离且经过认证加密的 WebShare HTTP upload 边界（`POST /api/web/upload`）；
  WebShare HTTP upload 严禁作为 App 间传输的降级后门。
- 按 V2 控制面决定，text/clipboard 继续走 authenticated LAN HTTPS + application
  E2E；不得为了迁移创建临时 native message implementation，也不得提供明文或逐消息
  关闭 E2E 的开关。
- 不把密钥、PIN、Bearer Token、Relay credential 或远端 localPath 写入明文
  数据库；接收文件必须经过 LAN sandbox 校验。
- Relay 设置只能通过 `LanRelaySettingsViewModel` 和注入的 Receiver Coordinator
  修改；页面 Token 只在当前表单调用中存在。endpoint 变化必须先断开旧 socket、
  清除旧 enrollment；Relay 断线按服务端 `retry_disposition` 重连：`retryAfter`
  使用建议秒数（上限 60s）、`refreshCredentialThenRetry`/`credentialExpired`
  静默刷新凭据、`noRetry`/`identityConflict` 终止，默认回退 `1/2/4/8/16/30` 秒
  指数退避最多六次。
- Relay 数据面只由 native NetworkService/Runtime 持有一个 socket。Dart 只负责
  enrollment、secure storage 和状态展示；发送前必须使用最终 Peer 状态，历史必须
  保留实际 Direct/Relay route metadata。
- Receiver 启动只确保 `NetworkCapability.runtime`，不得把 QUIC capability 当作
  native command gateway 的隐式前置条件；NetworkRuntime/native handle 仍由 App
  Scope Owner 释放。
- Receiver 必须为 LAN HTTPS 与 native QUIC/TCP 配置独立端口，并只发布 native
  实际绑定成功的端口。发送文件使用已发现或经认证 capabilities 返回的 native
  端口，不得回退到 HTTPS 端口猜测。
- Wave 1 当前唯一的数据面配置仍走现有 `ConfigureRuntime`，会无条件初始化直接
  QUIC/TCP 基础设施；QUIC-free WSS-only 数据面路径推迟到后续协议能力切换（Wave 2），
  当前并不存在。`runtime` 只表示 native command-worker handle 存在。
- 修改 Dart 文件后运行本 Package 的 format、analyze 和 test；Drift 输入变化
  后重新生成并确认 `*.g.dart` 与输入一致。

## Step29 标准字段

- 允许修改范围：LAN 发现、配对、传输、Receiver、Module、Repository、页面和测试。
- 禁止依赖：SSH、其他 Feature 实现、App `/src/`、未注入 native network 或明文秘密。
- Public API 修改要求：Feature Module、页面和 Port 只通过
  `feature_lan_share.dart`；纯 Dart WebShare worker 的窄边界通过
  `lan_web_share.dart` 暴露，并同步 App/Network adapters、安全测试和文档。
  使用 `network_sdk` 客户端契约时，必须同时验证 gateway 的借用式生命周期。
- 数据库约束：`LanShareModule` 独占 `lan_share.db`；只保存非秘密历史和配对 metadata。
- 资源释放规则：Module 负责 Receiver、HTTPS/WebSocket、Timer、数据库和 Repository；Network/App Owner 负责注入资源。Feature 不得关闭
  `NetworkRuntime` 或 `NetworkCommandGateway` 背后的 native handle。
- 必须运行的测试：`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test`。

## LAN Control V2 targeted acceptance

在完整 Feature 套件之外，涉及本契约的变更至少运行以下定向测试（测试文件
不存在时应先由实现提交补齐，不得用空选择器替代）：

- `test/services/lan_peer_trust_v2_test.dart`：schema reset、完整原子 trust、
  identity/key 校验和 Relay authorization；
- `test/features/lan_native_peer_registry_v2_test.dart`：restore、空 endpoint、
  endpoint invalidation、显式 unpair/remove、isolated restore；
- `test/services/lan_pairing_protocol_v2_test.dart`：transcript identity binding、atomic
  commit、旧协议拒绝和 timeout 无持久 half-pair；
- `test/services/lan_peer_trust_identity_v2_test.dart`：证书/X25519/Network Identity
  conflict fail-closed；
- `test/services/lan_peer_presentation_models_test.dart`：Discovery-only model 与
  trusted-offline aggregate；
- `test/services/lan_native_transfer_coordinator_v2_test.dart`：Network V2 regular-file
  transfer、incoming offer decisions、fresh policy relay fallback、unspecified route fail-closed；
- `test/features/network_incoming_transfer_host_test.dart`：incoming approval dialog state machine、
  retryable error retry、non-retryable failure snackbar、double-submit protection；
- `test/services/lan_storage_service_test.dart`：real disk space preflight with 100MiB safety buffer、
  fail-closed on unknown space、stream-copy fallback on cross-filesystem rename failure、sandbox delete security boundary；
- `test/features/lan_network_v2_acceptance_matrix_test.dart`：端到端 offline relay、direct->relay fallback、
  blocked incoming rejection、re-pair reconciliation、neutral inbox to sandbox adoption、cross-layer outgoing/incoming history lifecycle；
- `scripts/bash/contracts/check_network_v2_contract.dart`：Protocol V2 schema wire parity 跨 canonical proto、
  Rust prost structs 与 Dart codecs 的块结构级别自动化门禁（包括 `PeerTransferProgressEvent` tag 32 与 tag 1..5 parity）；
- `test/services/lan_http_v2_route_test.dart`：旧 `/api/lan/upload` 路径不存在。
- `test/services/lan_web_share_request_handler_test.dart`：WebShare production
  route handler 的有界正文 drain、早期拒绝、oversize/chunked overrun、加密上传和
  active upload cleanup；该测试不依赖 App 的 native TLS listener。

AppRuntime exactly-once 由 Full App 的
`test/app/network_runtime_ownership_v2_test.dart` 覆盖；SDK explicit lifecycle
由 `network_facade_v2_refactor_test.dart` 与 package contract tests 覆盖。

这些 Feature 测试必须由 Bash 与 PowerShell 的同名
`lan-network-v2-targeted` CI 选择共同覆盖；SDK/App adapter 的对应 contract
测试见 `network_sdk` README 和 App Shell 组合根文档。
