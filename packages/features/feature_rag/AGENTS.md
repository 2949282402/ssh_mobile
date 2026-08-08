最新更新时间：2026-08-08

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
