最新更新时间：2026-08-24

# feature_ai 维护约束

## 允许修改范围

允许修改 AI chat、Agent、Skills、LLM provider/runtime、工具编排、`AiModule`、
`ai.db` Repository、公共 Port 和本 Package 测试；App Shell 适配器只能放在 App。

## 禁止依赖

AI 只依赖 `app_core`、`app_ui`、`connection_core`、`ssh_core` 和显式的
`feature_playbook` 公共契约；禁止导入其他 Feature 的 `/src/`、App 实现或静态
全局 Network/SSH/Storage。RAG、MCP、WebView 等能力必须通过 Port/Capability 注入。

## Public API 修改要求

调用方只能使用 `package:feature_ai/feature_ai.dart` 及明确的分类公共出口。修改
`AiStoragePort`、`AiSshPort`、工具安全策略或 `AiModule` 时，必须同步 App 适配器、
测试、架构守卫 Allowlist 和根架构文档。

## 数据库约束

`AiModule` 独占 `ai.db`；聊天、Agent metrics、trace 和敏感字段写入前必须加密。
数据库打开失败不得静默回退到内存实现，凭据和 API Key 只能进入 Secure Storage。

## 资源释放规则

`AiModule` 负责 AI 数据库和 Repository；Route Scope 负责 Chat/Skills ViewModel、
Stream、Timer 和 Controller。App Shell 注入的 SSH、WebView、日志和数据保护资源
仍由各自 App Scope Owner 释放。

Tool loop 的 preflight、预算审计和结果折叠是独立安全 Owner：隐藏工具必须在预算、
审批、cache 和执行前被 preflight 拒绝；顺序与并行路径必须共用 result recorder；
预算审计统一通过 budget coordinator 封禁剩余调用。不得把这些规则复制回 round loop。

## 必须运行的测试

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
```
