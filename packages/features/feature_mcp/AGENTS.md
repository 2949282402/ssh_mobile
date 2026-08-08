最新更新时间：2026-08-08

# MCP Feature Agent Notes

- MCP 的网络监听只允许 `localhost`/`127.0.0.1`，Token、Origin 和 JSON-RPC
  校验属于执行边界，不得下沉到页面。
- `McpModule` 是 `mcp.db`、活动 Repository、审批队列和 HTTP Server 的唯一
  Owner；禁止在 ViewModel、Feature 或 App Shell 重复创建这些资源。
- `McpToolExecutor` 只能通过 App Shell 适配器注入，禁止 Package 导入 AI
  Feature、`apps/.../lib/src/` 或旧 `AiToolService`。
- 新增工具时同步检查暴露策略、调用审批策略、脱敏活动记录和对应测试。
