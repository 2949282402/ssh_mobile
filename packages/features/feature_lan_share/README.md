最新更新时间：2026-08-24

# feature_lan_share

LAN Quick Share 的独立 Feature Package，负责设备发现、配对、HTTPS/WebSocket
传输、WSS Relay enrollment/数据面编排、Web Share、传输历史和配对元数据。

## 边界

- 只通过 `app_core`、`app_ui`、`network_transport`、`network_sdk` 及本包定义的
  Port 使用 App 设置、日志、数据保护、网络和 Relay 能力；`network_sdk` 只提供
  Flutter 客户端契约和 canonical 网络模型，不拥有传输实现；本 Feature 不再维护
  本地网络模型桥接。
- 不依赖 SSH、其他 Feature 的实现或 App 的 `/src/` 路径。
- `LanShareModule` 独占 `lan_share.db`、历史 Repository 和接收器资源；App
  Shell 只注入 App Scope 资源并负责配置是否激活接收器。
- `LanReceiverCoordinator` 负责 LAN listener、discovery、pairing、原生 Facade
  创建和 ViewModel 生命周期；其内部 `LanRelayCoordinator` 独占 enrollment、
  credential refresh、Relay 事件订阅和有限重连状态机，只借用 Receiver 创建的
  Facade，并通过纯 Dart `LanRelay*Port` 借用 endpoint、日志、enrollment 和 capability，
  绝不停止或释放 App Scope Runtime。
- 数据库只保存传输历史和不含密钥、Token 的配对元数据；密钥、PIN、Bearer
  Token 和 Relay 凭据继续由安全存储边界管理。
- Relay 设置页只接收当前会话的 enrollment Token；Token 不进入偏好设置、数据库、
  日志或导出。Relay origin 可持久化，但更换 origin 会先断开旧 socket 并清除旧
  enrollment。原生层只保持一个 Relay socket，直连优先、Relay 兜底；断线按
  服务端 `retry_disposition` 重连（`retryAfter` 用建议秒数、`credentialExpired`
  静默刷新凭据、`noRetry`/`identityConflict` 终止），默认 `1/2/4/8/16/30` 秒
  指数退避最多六次，传输历史记录实际的 Direct/Relay 路线。
- Wave 1 中唯一的数据面配置仍走现有 `ConfigureRuntime`，该入口会无条件初始化直接
  QUIC/TCP 基础设施；QUIC-free WSS-only 数据面路径推迟到后续协议能力切换（Wave 2），
  当前并不存在。`NetworkCapability.runtime` 只表示 native command-worker handle
  存在，不代表 WSS 数据面已独立配置。

旧 `apps/ssh_mobile_full/lib/features/lan_share/**`、
`apps/ssh_mobile_full/lib/services/lan_share/**` 和 Relay facade 已删除；
App Shell 只保留 `lan_share_feature_adapters.dart` 以及 Network Protocol V2 network
创建边界。

## Package contract

- 职责：提供 LAN 发现、配对、HTTPS/WebSocket 传输、WSS Relay enrollment/状态、
  Web Share 和传输历史。
- 不负责：SSH、其他 Feature 实现、App `/src/`、未审批的网络写入或秘密持久化。
- Public API：`package:feature_lan_share/feature_lan_share.dart`，包括 Module、
  Receiver 配置、页面和 Port。
- 依赖：`app_core`、`app_ui`、`network_transport`、`network_sdk` 及 LAN 直接插件。
- 数据库：`LanShareModule` 独占 `lan_share.db`，只存历史和非秘密配对 metadata。
- 生命周期与资源 Owner：Module 负责数据库、历史 Repository、Receiver；Receiver
  内部 Relay Owner 负责 Relay Timer、credential client 和事件订阅，Module 仍负责
  等待两者关闭；Module 还负责
  WebSocket/HTTPS 资源；AppRuntime/NetworkRuntime 负责注入的 App Scope 资源。
  Receiver 初始化只请求 `NetworkCapability.runtime`；App Shell adapter 将
  Runtime-owned `NetworkCommandGateway`（因此不隐式要求 QUIC）适配为
  `network_sdk.SessionClient`，并将控制面请求执行器组装为
  `network_sdk.BootstrapClient`；Feature 只能释放自己的订阅和 Session 使用状态。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
