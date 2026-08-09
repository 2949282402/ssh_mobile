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
