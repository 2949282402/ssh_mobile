最新更新时间：2026-08-30

# feature_rag

RAG 运维知识库 Feature。Package 独占 `rag.db`、文档/索引元数据 Repository
和有限的本地文档块缓存；数据库不保存大段原文或向量正文。

## 边界

- `RagModule` 持有数据库、Repository、缓存 Store 和 `RagService` 的生命周期。
- AI 只通过 `RagCapability` 检索，不依赖页面或其他 Feature 的实现。
- API Key、搜索模式和日志通过 App Shell 注入的 Port 提供。
- 文档缓存有单文件/总大小上限、TTL 和按最近访问时间淘汰策略。
- 文档入口同时限制源文件、PDF page/stream 数、单流压缩与解压大小、累计提取
  文本、chunk 数和 embedding 输入字符；PDF 解压使用有界输出流，拒绝压缩炸弹。
- `RagService.close()` 等待缓存、数据库和 embedding 操作收敛后，`RagModule` 才
  关闭 `rag.db`；Module 代次阻止 dispose 后迟到初始化重新挂载资源。
- 不读取或迁移旧 `rag_database.json`、`rag_metadata.json` 或旧 App Database。

App Shell 只能依赖 `package:feature_rag/feature_rag.dart`，不得引用 Package 的
`src/` 路径。

旧 App RAG 页面、Service、测试和兼容 facade 已删除；App Shell 只保留
`rag_feature_adapters.dart`，旧开发数据库文件不迁移。

公共入口提供知识库路由的纯 metadata；App Shell 负责聚合路由描述，RAG ViewModel
仍由 Route Scope 创建和释放。

## Package contract

- 职责：提供文档解析、BM25/vector/Hybrid 检索、元数据 Repository 和受限缓存。
- 不负责：AI 页面、Embedding/API Key 具体实现、旧 RAG 文件迁移或其他 Feature 实现。
- Public API：`package:feature_rag/feature_rag.dart`，包括 `RagCapability` 和路由 metadata。
- 依赖：`app_core`、`app_ui`、Flutter、Drift、Provider、文件/网络解析插件和缓存所需 SDK。
- 数据库：`RagModule` 独占 `rag.db`；只保存元数据，不保存大段正文或大向量。
- 生命周期与资源 Owner：Module 负责数据库、Repository、Cache Store、Service
  关闭屏障和初始化代次；Route Scope 负责 `RagViewModel`；AppRuntime 注入设置、
  日志和 API Key Port。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
