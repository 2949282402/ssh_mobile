最新更新时间：2026-08-24

# feature_mcp

本 Package 提供本地回环 MCP Streamable HTTP Server、工具暴露策略、执行层二次
审批队列、协议自检和脱敏活动记录。

## 边界

- `McpModule` 独占 `mcp.db`、活动 Repository、审批队列和 HTTP Server。
- 工具执行、设置持久化和日志通过 `McpToolRuntimePort`、`McpSettingsPort`、
  `McpLoggerPort` 注入；Package 不依赖旧 AI Service 或共享业务数据库。
- `tools/call` 的 `approval_required`、目标绑定和 fail-closed 策略在执行层，
  控制台页面只负责展示和批准/拒绝。
- 调用方只允许从 `package:feature_mcp/feature_mcp.dart` 使用公共 API。
- 公共入口提供 MCP 路由的纯 metadata；App Shell 只聚合描述并在 Route Scope 创建
  控制台状态，Core 不持有 Widget、ViewModel 或 Module 实例。
- `McpSelfTestRunner` 独立拥有 initialize → tools/list 协议诊断和稳定结果落账；
  Server Controller 只注入短生命周期 HTTP transport，不复制自检状态机。

## 生命周期

AppRuntime 注册、初始化并激活 `McpModule`，应用生命周期在退出时先停止 Server，
再释放 Module 和 `mcp.db`。路由通过 `McpFeatureScope` 创建 ViewModel，路由退出
只释放自己的 ViewModel。
`start/stop/checkPort/close` 串行化；`close()` 立即使旧 generation 失效，并等待迟到
bind 与活动 HTTP listener 完成关闭后，Module 才关闭审批队列和数据库。

## 验证

```text
dart format --output=none --set-exit-if-changed lib test
dart analyze
flutter test --no-pub --exclude-tags native-loopback
```

`test/services/mcp/mcp_http_server_native_test.dart` 是真实回环 HTTP 集成测试，
在原生 Linux CI 中运行；WSL 的 Flutter tester 不运行该标签测试。生产 Server
仍只允许绑定 `localhost`/`127.0.0.1`。

## Package contract

- 职责：提供本地 MCP HTTP Server、JSON-RPC、工具暴露/调用策略、审批队列、活动记录
  和控制台页面。
- 不负责：远端 MCP、AI Tool Runtime 实现、共享业务数据库或 App Shell 设置实现。
- Public API：`package:feature_mcp/feature_mcp.dart`，包括 `McpModule`、Ports、
  路由 metadata 和 `McpFeatureScope`。
- 依赖：`app_core`、`app_ui`、Drift、Provider 和 Flutter SDK。
- 数据库：`McpModule` 独占 `mcp.db`；活动记录不得回流统一 `AppDatabase`。
- 生命周期与资源 Owner：Module 负责数据库、Server、审批队列和 Repository；Route
  Scope 负责 ViewModel；AppRuntime 注入设置、日志和 AI Tool Runtime。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub --exclude-tags
  native-loopback`；原生 Linux 额外运行 `flutter test --tags native-loopback
  test/services/mcp/mcp_http_server_native_test.dart`。
