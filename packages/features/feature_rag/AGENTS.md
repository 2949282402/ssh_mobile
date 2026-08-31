最新更新时间：2026-08-30

# feature_rag 维护约束

- `src/domain/` owns RAG models/App-AI contracts; `src/data/` owns `rag.db`,
  metadata Repository, and bounded file cache (no document body or large vector
  cache); `src/application/` owns Module/Service lifecycle; `src/features/rag/`
  owns pages and Route ViewModels.
- Every cache write goes through `RagCachePolicy` (size/TTL/eviction). App
  capabilities arrive through public entry points/Ports; no other Feature/App
  implementation, old RAG file, or unified DB.
- Contract: allowed models/parser/retrieval Service/cache policy/Module/Repository/
  pages/tests; public API only `feature_rag.dart`/`RagCapability`, syncing AI
  adapters/tests. `RagModule` owns DB/Repository/Cache/Service; Route owns VM.

## 验证（代码变更）

DB changes: `dart run build_runner build` and review `rag_database.g.dart`; then
`flutter analyze`/`flutter test`. Local aggregate CI is user-opt-in.
