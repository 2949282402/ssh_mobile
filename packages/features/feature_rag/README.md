最新更新时间：2026-08-09

# feature_rag

RAG 运维知识库 Feature。Package 独占 `rag.db`、文档/索引元数据 Repository
和有限的本地文档块缓存；数据库不保存大段原文或向量正文。

## 边界

- `RagModule` 持有数据库、Repository、缓存 Store 和 `RagService` 的生命周期。
- AI 只通过 `RagCapability` 检索，不依赖页面或其他 Feature 的实现。
- API Key、搜索模式和日志通过 App Shell 注入的 Port 提供。
- 文档缓存有单文件/总大小上限、TTL 和按最近访问时间淘汰策略。
- 不读取或迁移旧 `rag_database.json`、`rag_metadata.json` 或旧 App Database。

App Shell 只能依赖 `package:feature_rag/feature_rag.dart`，不得引用 Package 的
`src/` 路径。

公共入口提供知识库路由的纯 metadata；App Shell 负责聚合路由描述，RAG ViewModel
仍由 Route Scope 创建和释放。
