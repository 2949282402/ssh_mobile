最新更新时间：2026-08-13

# LAN Share Package Guidelines

- 业务、协议和安全行为迁移自旧 LAN Quick Share 实现，修改时优先保持兼容。
- Package 不得导入 SSH、其他 Feature 实现或 App 的 `/src/`；跨边界能力必须
  通过 `LanShare*Port` 注入。
- 网络客户端契约统一来自 `network_sdk`；Feature 只消费 `NetworkFacade`，不得
  自行创建 Socket、FFI、HTTP client、native handle 或第二套传输实现。
  `BootstrapClient` 和 `NetworkCommandGateway` 只能由 App Shell adapter 注入；
  网络结果、Session、Event 和 Facade 类型必须直接从 `network_sdk` 导入，
  不得恢复本地模型桥接。
- `LanShareModule` 是 `lan_share.db`、Repository、Receiver 和 Route Service
  的 Owner；Route Scope 只负责 ViewModel 生命周期。
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
- Wave 1 当前唯一的数据面配置仍走现有 `ConfigureRuntime`，会无条件初始化直接
  QUIC/TCP 基础设施；QUIC-free WSS-only 数据面路径推迟到 v1 协议切换（Wave 2），
  当前并不存在。`runtime` 只表示 native command-worker handle 存在。
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
