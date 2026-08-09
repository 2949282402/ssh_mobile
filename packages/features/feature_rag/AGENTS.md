最新更新时间：2026-08-09

# RAG Feature 维护说明

- `src/domain/` 定义 RAG 模型和 App/AI Contract。
- `src/data/` 负责 `rag.db`、元数据 Repository 和受限文件缓存；数据库不保存
  文档正文及大型向量缓存。
- `src/application/` 负责 Module 和 Service 生命周期。
- `src/features/rag/` 只负责 RAG 页面及 Route-scoped ViewModel。
- 修改数据库表后运行 `dart run build_runner build`，并提交生成的
  `rag_database.g.dart`。
- 所有缓存写入都必须经过 `RagCachePolicy`，不得绕过大小、TTL 和淘汰规则。
- App 依赖只能通过公共入口和 Port 注入，禁止引用其他 Feature 或 App 的实现。

## Step29 标准字段

- 允许修改范围：RAG 模型、解析器、检索 Service、Cache Policy、Module、Repository、页面和测试。
- 禁止依赖：AI/RAG 之外的 Feature 实现、App `/src/`、旧 RAG 文件或统一数据库。
- Public API 修改要求：只通过 `feature_rag.dart` 和 `RagCapability`，同步 AI adapters 和测试。
- 数据库约束：`RagModule` 独占 `rag.db`；只保存元数据，正文和向量正文留在受限缓存。
- 资源释放规则：Module 释放数据库、Repository、Cache Store 和 Service；Route Scope 释放 ViewModel。
- 必须运行的测试：`dart run build_runner build`、`flutter analyze`、`flutter test`。
