最新更新时间：2026-08-09

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

## 生命周期

AppRuntime 注册、初始化并激活 `McpModule`，应用生命周期在退出时先停止 Server，
再释放 Module 和 `mcp.db`。路由通过 `McpFeatureScope` 创建 ViewModel，路由退出
只释放自己的 ViewModel。

## 验证

```text
dart format --output=none --set-exit-if-changed lib test
dart analyze
flutter test
```

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
  `flutter analyze --no-pub`、`flutter test --no-pub`。
