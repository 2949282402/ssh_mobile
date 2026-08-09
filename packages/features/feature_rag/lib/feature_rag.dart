// RAG Feature 的稳定公共入口。
//
// App Shell、AI 和测试只通过本文件获取 Module、Port、Capability、Route
// Scope 与页面，避免跨 Package 引用内部实现。
library;

import 'package:app_core/app_core.dart';

export 'src/application/rag_module.dart';
export 'src/application/rag_service.dart';
export 'src/data/cache/rag_cache_store.dart';
export 'src/data/database/rag_database.dart';
export 'src/data/repositories/rag_repository.dart';
export 'src/domain/rag_models.dart';
export 'src/domain/rag_ports.dart';
export 'src/features/rag/viewmodels/rag_knowledge_viewmodel.dart';
export 'src/features/rag/views/rag_knowledge_screen.dart';
export 'src/presentation/rag_feature_scope.dart';
export 'src/processing/bm25_search.dart' show Bm25SearchEngine, ScoredRagChunk;
export 'src/processing/pdf_text_extractor.dart';
export 'src/processing/text_chunker.dart' show TextChunker;
export 'src/processing/vector_search_utils.dart';

/// RAG Feature 对外公布的稳定路由名称。
abstract final class RagRouteNames {
  /// 知识库页面。
  static const knowledge = '/rag-knowledge';
}

/// RAG Feature 的路由元数据贡献；App Shell 负责解释页面构建。
final List<ModuleRouteContribution> ragRouteContributions = List.unmodifiable([
  ModuleRouteContribution(routeName: RagRouteNames.knowledge),
]);
