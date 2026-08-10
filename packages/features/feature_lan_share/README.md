最新更新时间：2026-08-10

# feature_lan_share

LAN Quick Share 的独立 Feature Package，负责设备发现、配对、HTTPS/WebSocket
传输、Web Share、传输历史和配对元数据。

## 边界

- 只通过 `app_core`、`app_ui`、`network_transport`、`network_sdk` 及本包定义的
  Port 使用 App 设置、日志、数据保护、网络和 Relay 能力；`network_sdk` 只提供
  Flutter 客户端契约，不拥有传输实现。
- 不依赖 SSH、其他 Feature 的实现或 App 的 `/src/` 路径。
- `LanShareModule` 独占 `lan_share.db`、历史 Repository 和接收器资源；App
  Shell 只注入 App Scope 资源并负责配置是否激活接收器。
- 数据库只保存传输历史和不含密钥、Token 的配对元数据；密钥、PIN、Bearer
  Token 和 Relay 凭据继续由安全存储边界管理。

旧 `apps/ssh_mobile_full/lib/features/lan_share/**` 与
`apps/ssh_mobile_full/lib/services/lan_share/**` 在本迁移阶段保留为兼容面，
不会被批量删除。

## Package contract

- 职责：提供 LAN 发现、配对、HTTPS/WebSocket 传输、Web Share 和传输历史。
- 不负责：SSH、其他 Feature 实现、App `/src/`、未审批的网络写入或秘密持久化。
- Public API：`package:feature_lan_share/feature_lan_share.dart`，包括 Module、
  Receiver 配置、页面和 Port。
- 依赖：`app_core`、`app_ui`、`network_transport`、`network_sdk` 及 LAN 直接插件。
- 数据库：`LanShareModule` 独占 `lan_share.db`，只存历史和非秘密配对 metadata。
- 生命周期与资源 Owner：Module 负责数据库、历史 Repository、Receiver、Timer、
  WebSocket/HTTPS 资源；AppRuntime/NetworkRuntime 负责注入的 App Scope 资源。
  App Shell adapter 将 Runtime-owned `NetworkCommandGateway` 适配为
  `network_sdk.SessionClient`，并将控制面请求执行器组装为
  `network_sdk.BootstrapClient`；Feature 只能释放自己的订阅和 Session 使用状态。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
