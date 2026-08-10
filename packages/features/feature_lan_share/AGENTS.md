最新更新时间：2026-08-10

# LAN Share Package Guidelines

- 业务、协议和安全行为迁移自旧 LAN Quick Share 实现，修改时优先保持兼容。
- Package 不得导入 SSH、其他 Feature 实现或 App 的 `/src/`；跨边界能力必须
  通过 `LanShare*Port` 注入。
- 网络客户端契约统一来自 `network_sdk`；Feature 不得自行创建 Socket、FFI、
  HTTP client、native handle 或第二套传输实现。`BootstrapClient` 和
  `NetworkCommandGateway` 只能由 App Shell adapter 注入。
- `LanShareModule` 是 `lan_share.db`、Repository、Receiver 和 Route Service
  的 Owner；Route Scope 只负责 ViewModel 生命周期。
- 不把密钥、PIN、Bearer Token、Relay credential 或远端 localPath 写入明文
  数据库；接收文件必须经过 LAN sandbox 校验。
- 修改 Dart 文件后运行本 Package 的 format、analyze 和 test；Drift 输入变化
  后重新生成并确认 `*.g.dart` 与输入一致。

## Step29 标准字段

- 允许修改范围：LAN 发现、配对、传输、Receiver、Module、Repository、页面和测试。
- 禁止依赖：SSH、其他 Feature 实现、App `/src/`、未注入 native network 或明文秘密。
- Public API 修改要求：只通过 `feature_lan_share.dart`，同步 App/Network adapters、安全测试和文档。
  使用 `network_sdk` 客户端契约时，必须同时验证 gateway 的借用式生命周期。
- 数据库约束：`LanShareModule` 独占 `lan_share.db`；只保存非秘密历史和配对 metadata。
- 资源释放规则：Module 负责 Receiver、HTTPS/WebSocket、Timer、数据库和 Repository；Network/App Owner 负责注入资源。Feature 不得关闭
  `NetworkRuntime` 或 `NetworkCommandGateway` 背后的 native handle。
- 必须运行的测试：`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test`。
