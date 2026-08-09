最新更新时间：2026-08-09

# Terminal-only App Guidelines

- 本 App 只验证最小 Terminal 编译图，不复制 Full App 的业务 Service。
- App Scope 资源由 `lib/app/terminal_app_runtime.dart` 统一创建和释放。
- Terminal 页面只能通过 `feature_terminal` 的公共入口和 Port 使用能力，
  禁止导入其他 Package 的 `lib/src/`。
- 不得添加 AI、RAG、MCP、WebView、LAN Share 或 SFTP 依赖；需要扩展完整
  产品能力时应修改 Full App 或对应 Feature，而不是扩大这个验证切片。
- 新增资源必须在同一 Owner 或明确的上级 Owner 中提供 `dispose`、`close`、
  `cancel` 或 `release`。

## Step29 标准字段

- 允许修改范围：最小 App Shell、Runtime、Terminal 测试和裁剪验证文档。
- 禁止依赖：AI、RAG、MCP、WebView、LAN Share、SFTP 或 Full App `/src/`。
- Public API 修改要求：同步 `TerminalFeatureScope`、Runtime 注入方、测试和依赖裁剪说明。
- 数据库约束：只允许 `TerminalModule` 拥有 `terminal.db`，不得创建未选择 Feature 数据库。
- 资源释放规则：Runtime 释放 App Scope；Module 释放数据库；Route Scope 释放页面资源。
- 必须运行的测试：`flutter pub deps`、`flutter analyze`、`flutter test`。
