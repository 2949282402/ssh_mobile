最新更新时间：2026-08-20

# MCP Feature Agent Notes

- MCP 的网络监听只允许 `localhost`/`127.0.0.1`，Token、Origin 和 JSON-RPC
  校验属于执行边界，不得下沉到页面。
- `McpModule` 是 `mcp.db`、活动 Repository、审批队列和 HTTP Server 的唯一
  Owner；禁止在 ViewModel、Feature 或 App Shell 重复创建这些资源。
- `McpToolExecutor` 只能通过 App Shell 适配器注入，禁止 Package 导入 AI
  Feature、`apps/.../lib/src/` 或旧 `AiToolService`。
- 新增工具时同步检查暴露策略、调用审批策略、脱敏活动记录和对应测试。

## Step29 标准字段

- 允许修改范围：MCP Server、JSON-RPC、暴露/调用策略、审批队列、活动 Repository、Module、页面和测试。
- 禁止依赖：AI Feature 实现、旧 `AiToolService`、App `/src/` 或共享业务数据库。
- Public API 修改要求：只通过 `feature_mcp.dart`，同步 App adapters、路由 metadata、审批和安全测试。
- 数据库约束：`McpModule` 独占 `mcp.db`；活动记录不得回流统一 `AppDatabase`，秘密只保留在安全边界。
- 资源释放规则：Module 停止 HTTP Server、拒绝 pending approval、关闭 Repository/数据库；Route Scope 释放 ViewModel。
- 必须运行的测试：`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test`。
- `mcp_http_server_native_test.dart` 标记为 `native-loopback`，需要原生 Linux
  Flutter runner；WSL 使用 `flutter test --exclude-tags native-loopback`，CI
  仍运行真实回环 HTTP 集成测试。
