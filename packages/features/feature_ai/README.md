最新更新时间：2026-08-24

# feature_ai

AI chat、Agent、Skills、LLM provider/runtime 和工具编排 Feature。Package 独占
`ai.db`，并通过 App Shell 注入远程命令、文件传输、监控、Playbook、RAG、MCP
等 Core Capability，不直接依赖其他 Feature 的实现。

## 边界

- `AiModule` 是 AI 数据库、Repository、保护端口和日志端口的生命周期 Owner；
  只有进入 AI 路由或明确发起 AI 请求时才打开 `ai.db`、创建 provider/runtime
  和工具注册表。
- `chat/`、`agent/`、`skills/`、`llm/`、`tools/` 和 `data/` 按业务子域拆分，
  不重新聚合为巨型 `ai_service.dart`。
- Tool round 控制器只保留顺序编排和执行/审批状态；可见性/计划门禁、预算审计以及
  provider message/system hint/ledger/trace 的统一结果折叠由独立 collaborator 持有，
  并行与顺序路径不得再复制不同的结果落账规则。
- 聊天、Agent metrics、trace 和消息敏感字段通过 `DriftAiRepository` 写入
  `ai.db`；加密能力由 App Shell 的 `AiTextProtectionPort` 注入，数据库异常
  不静默回退到内存实现。
- AI 只消费 `app_core` 的 Capability Contract 和显式 Port；RAG、Playbook、
  MCP 的实现仍由各自 Feature Module 持有。
- App Shell 只能依赖 `package:feature_ai/feature_ai.dart` 或分类公共出口，
  不得引用 Package 的 `src/` 路径。旧 `ai_chat`、`ai_skills` 和 AI service
  路径仅作为迁移期间的兼容边界。
- 公共入口提供 Skills 路由的纯 metadata；App Shell 只聚合路由描述，AI 页面状态仍由
  Route Scope 持有。

## 验证

```text
dart format --output=none --set-exit-if-changed lib test
dart analyze
flutter test
```

## Package contract

- 职责：提供 AI chat、Agent、Skills、LLM provider/runtime、工具编排和 `ai.db`。
- 不负责：SSH、SFTP、RAG、MCP、WebView、日志或设置的具体 App 实现。
- Public API：`package:feature_ai/feature_ai.dart` 及分类公共出口；不得引用 `src/`。
- 依赖：`app_core`、`app_ui`、`connection_core`、`feature_playbook`、`ssh_core`、
  Flutter/Provider、Drift 和 AI 直接插件。
- 数据库：`AiModule` 独占 `ai.db`，正文/trace/metrics 等敏感字段写入前加密。
- 生命周期与资源 Owner：Module 负责数据库/Repository；Route Scope 负责 AI 页面
  ViewModel、Stream、Timer 和 Controller；AppRuntime 负责注入的 App Ports。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
