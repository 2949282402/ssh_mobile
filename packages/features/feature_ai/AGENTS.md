最新更新时间：2026-08-30

# feature_ai 维护约束

- Scope：AI chat/Agent/Skills/LLM provider/runtime、tool orchestration,
  `AiModule`/`ai.db` Repository、公共 Ports 和本包测试；App adapters 留在 App。
- 依赖仅 `app_core`、`app_ui`、`connection_core`、`ssh_core`、显式
  `feature_playbook` 公共契约；RAG/MCP/WebView 等通过 Port/Capability 注入，
  禁止其他 Feature `/src/`、App implementation、静态全局 Network/SSH/Storage。
- 公开 API 只能从 `package:feature_ai/feature_ai.dart`/分类出口使用。修改 `AiStoragePort`、
  `AiSshPort`、安全策略或 Module 时同步 App adapters、测试、架构守卫/文档。
- `AiModule` 独占 `ai.db`；chat/metrics/trace 等敏感字段写入前加密，DB 打开
  失败不得回退内存，凭据/API key 只进 Secure Storage。
- Module 负责 DB/Repository；Route Scope 负责 Chat/Skills ViewModel、Stream、
  Timer、Controller。App 注入的 SSH/WebView/log/protection 资源由 App Owner 释放。
- Tool-loop preflight（visibility/plan）、budget coordinator（extension/blocking）
  和 result recorder（串行/并行 provider message/system hint/ledger/trace）是
  独立安全 Owner；隐藏工具必须在 budget/approval/cache/执行前拒绝。修改
  loop、approval、budget、plan、cancel/close、provider error、trace/ledger 时先
  添加失败行为/安全/生命周期测试，不只断言 mock 顺序。

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze --no-pub`、
`flutter test --no-pub`；local aggregate CI 仅按用户明确要求运行。
