import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../utils/platform_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../utils/bm25_search.dart';
import '../utils/pdf_text_extractor.dart';
import '../utils/text_chunker.dart';
import '../utils/vector_search_utils.dart';
import 'app_log_service.dart';
import 'storage_service.dart';

class RagDocumentMetadata {
  final String id;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final DateTime uploadedAt;
  final int chunkCount;

  const RagDocumentMetadata({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.chunkCount,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'uploadedAt': uploadedAt.toIso8601String(),
      'chunkCount': chunkCount,
    };
  }

  factory RagDocumentMetadata.fromJson(Map<String, dynamic> json) {
    return RagDocumentMetadata(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      uploadedAt:
          DateTime.tryParse(json['uploadedAt'] as String? ?? '') ??
          DateTime.now(),
      chunkCount: json['chunkCount'] as int? ?? 0,
    );
  }
}

class RagService extends ChangeNotifier {
  final StorageService storageService;
  final List<RagDocumentMetadata> _documents = [];
  final Bm25SearchEngine _searchEngine = Bm25SearchEngine();
  bool _isLoading = false;
  bool _isInitialized = false;

  Future<void>? _initFuture;

  RagService({required this.storageService});

  List<RagDocumentMetadata> get documents => List.unmodifiable(_documents);
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;

  /// 初始化 RAG 服务，支持 legacy 数据库迁移与仅加载元数据
  Future<void> init({bool force = false}) {
    if (force) {
      _initFuture = null;
      _isInitialized = false;
    }
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    _isLoading = true;
    notifyListeners();

    try {
      await storageService.initFuture;
      final supportDir = await getApplicationSupportDirectory();
      final legacyFile = File(p.join(supportDir.path, 'rag_database.json'));
      final metadataFile = File(p.join(supportDir.path, 'rag_metadata.json'));

      if (await legacyFile.exists()) {
        AppLogService.instance.info('RAG: Legacy database found, migrating...');
        final content = await legacyFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;

        // 1. 加载文档元数据
        final rawDocs = json['documents'] as List? ?? [];
        _documents.clear();
        for (final docJson in rawDocs) {
          if (docJson is Map<String, dynamic>) {
            _documents.add(RagDocumentMetadata.fromJson(docJson));
          }
        }

        // 2. 加载文档分块并将其切分为独立的文档文件
        final rawChunks = json['documentChunks'] as Map<String, dynamic>? ?? {};
        for (final entry in rawChunks.entries) {
          final docId = entry.key;
          final chunksList = entry.value as List? ?? [];
          final docFile = File(p.join(supportDir.path, 'rag_doc_$docId.json'));
          await docFile.writeAsString(jsonEncode(chunksList));
        }

        // 3. 加载搜索引擎索引状态
        final searchJson = json['searchEngine'] as Map<String, dynamic>?;
        if (searchJson != null) {
          _searchEngine.loadFromJson(searchJson);
          _searchEngine.chunks.clear(); // 确保不把 chunks 缓存在内存中
        }

        // 4. 保存为新的轻量级元数据
        await _saveMetadataAndIndex(supportDir.path);

        // 5. 删除 legacy 文件
        await legacyFile.delete();
        AppLogService.instance.info(
          'RAG: Migration completed and legacy file deleted.',
        );
      } else if (await metadataFile.exists()) {
        final content = await metadataFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;

        // 加载文档元数据
        final rawDocs = json['documents'] as List? ?? [];
        _documents.clear();
        for (final docJson in rawDocs) {
          if (docJson is Map<String, dynamic>) {
            _documents.add(RagDocumentMetadata.fromJson(docJson));
          }
        }

        // 加载搜索引擎索引状态
        final searchJson = json['searchEngine'] as Map<String, dynamic>?;
        if (searchJson != null) {
          _searchEngine.loadFromJson(searchJson);
          _searchEngine.chunks.clear(); // 确保不把 chunks 缓存在内存中
        }
      }
      AppLogService.instance.info(
        'RAG service initialized',
        details: 'loadedDocs=${_documents.length}',
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'RAG service initialization failed',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _isLoading = false;
      _isInitialized = true;
      notifyListeners();
    }
  }

  /// 添加一个新文档，对其进行解析、分块、索引并持久化（分块写入独立文件）
  Future<RagDocumentMetadata> addDocument({
    required String name,
    required List<int> bytes,
    required String mimeType,
  }) async {
    await init(); // 确保加载完毕
    _isLoading = true;
    notifyListeners();

    try {
      final docId = const Uuid().v4();
      final supportDir = await getApplicationSupportDirectory();
      String text = '';

      // 1. 解析文本
      final lowerName = name.toLowerCase();
      if (lowerName.endsWith('.pdf') || mimeType == 'application/pdf') {
        text = PdfTextExtractor.extractText(bytes);
      } else {
        // 默认为文本文件直接解码
        text = utf8.decode(bytes, allowMalformed: true);
      }

      if (text.trim().isEmpty) {
        throw ArgumentError('未在文档中提取到有效文本内容。');
      }

      // 2. 对文本进行滑动窗口切块
      final chunks = TextChunker.split(
        text: text,
        documentId: docId,
        documentName: name,
        chunkSize: 600,
        chunkOverlap: 120,
      );

      if (chunks.isEmpty) {
        throw StateError('文本切块失败。');
      }

      // 2.5 尝试生成向量 Embedding (如果配置了阿里云 DashScope Key)
      final aliyunKey = await storageService.getAliyunApiKey();
      if (aliyunKey != null && aliyunKey.isNotEmpty) {
        try {
          final client = AliyunEmbeddingClient(apiKey: aliyunKey);
          final chunkTexts = chunks.map((c) => c.text).toList();
          final embeddings = <List<double>>[];

          // 通义千问 Embedding API 限制每次调用最多 25 个 texts
          const batchSize = 20;
          for (var i = 0; i < chunkTexts.length; i += batchSize) {
            final endIdx = i + batchSize > chunkTexts.length
                ? chunkTexts.length
                : i + batchSize;
            final batch = chunkTexts.sublist(i, endIdx);
            final batchEmbeddings = await client.getEmbeddings(
              batch,
              textType: 'document',
            );
            embeddings.addAll(batchEmbeddings);
          }

          // 将生成的语义向量写入分块的 metadata 中
          for (var i = 0; i < chunks.length; i++) {
            if (i < embeddings.length) {
              chunks[i].metadata['embedding'] = embeddings[i];
            }
          }
          AppLogService.instance.info(
            'RAG: Generated embeddings successfully via Aliyun',
          );
        } catch (e) {
          AppLogService.instance.warning(
            'RAG: Failed to generate vectors via Aliyun: $e. Falling back to pure BM25 index.',
          );
        }
      }

      // 3. 将当前文档的分块写入独立的 JSON 文件中
      final docFile = File(p.join(supportDir.path, 'rag_doc_$docId.json'));
      final chunksJson = chunks.map((c) => c.toJson()).toList();
      await docFile.writeAsString(jsonEncode(chunksJson));

      // 4. 将分块索引信息添加进搜索引擎，并清除 chunks 内存缓存
      _searchEngine.addChunks(chunks);
      _searchEngine.chunks.clear();

      // 5. 创建文档元数据
      final metadata = RagDocumentMetadata(
        id: docId,
        name: name,
        mimeType: mimeType,
        sizeBytes: bytes.length,
        uploadedAt: DateTime.now(),
        chunkCount: chunks.length,
      );

      _documents.add(metadata);

      // 6. 持久化元数据和索引状态
      await _saveMetadataAndIndex(supportDir.path);

      AppLogService.instance.info(
        'RAG document added successfully',
        details: 'docName=$name docId=$docId chunks=${chunks.length}',
      );

      return metadata;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'RAG add document failed',
        error: e,
        stackTrace: stackTrace,
        details: 'docName=$name',
      );
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 删除指定文档及相关的所有索引分块并持久化（后台 Isolate 重建搜索引擎索引）
  Future<void> deleteDocument(String documentId) async {
    await init();
    _isLoading = true;
    notifyListeners();

    try {
      final supportDir = await getApplicationSupportDirectory();

      // 1. 从元数据列表中移除
      _documents.removeWhere((doc) => doc.id == documentId);

      // 2. 删除独立的分块文件
      final docFile = File(p.join(supportDir.path, 'rag_doc_$documentId.json'));
      if (await docFile.exists()) {
        await docFile.delete();
      }

      // 3. 在后台 Isolate 中重建搜索引擎状态，以彻底清理该文档的倒排词频及长度信息
      final remainingDocIds = _documents.map((d) => d.id).toList();
      final newSearchEngineJson = await compute(_rebuildIndexTask, {
        'supportDirPath': supportDir.path,
        'documentIds': remainingDocIds,
        'k1': _searchEngine.k1,
        'b': _searchEngine.b,
      });

      _searchEngine.loadFromJson(newSearchEngineJson);
      _searchEngine.chunks.clear();

      // 4. 持久化新的元数据和索引状态
      await _saveMetadataAndIndex(supportDir.path);

      AppLogService.instance.info(
        'RAG document deleted successfully',
        details: 'docId=$documentId remainingDocs=${_documents.length}',
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'RAG delete document failed',
        error: e,
        stackTrace: stackTrace,
        details: 'docId=$documentId',
      );
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 根据 Query 检索最相关的文本分块。支持筛选特定的文档。
  Future<List<RagChunk>> retrieve(
    String query, {
    int limit = 3,
    Set<String>? filterDocumentIds,
    String? searchMode,
    String? aliyunApiKey,
  }) async {
    await init();
    if (_documents.isEmpty || query.trim().isEmpty) return const [];

    try {
      final effectiveSearchMode = switch (searchMode) {
        'vector' => 'vector',
        'hybrid' => 'hybrid',
        'bm25' => 'bm25',
        _ => switch ((await SharedPreferences.getInstance()).getString(
          'rag_search_mode',
        )) {
          'vector' => 'vector',
          'hybrid' => 'hybrid',
          _ => 'bm25',
        },
      };
      final aliyunKey = effectiveSearchMode == 'bm25'
          ? ''
          : (aliyunApiKey ?? await storageService.getAliyunApiKey() ?? '')
                .trim();
      final supportDir = await getApplicationSupportDirectory();

      // 如果选了向量/混合搜索，但没有配 Aliyun 密钥，则回退为 BM25 搜索
      if (effectiveSearchMode == 'bm25' || aliyunKey.isEmpty) {
        return await _retrieveBm25Isolated(
          query,
          limit,
          filterDocumentIds,
          supportDir.path,
        );
      }

      if (effectiveSearchMode == 'vector') {
        return await _retrieveVectorIsolated(
          query,
          aliyunKey,
          limit,
          filterDocumentIds,
          supportDir.path,
        );
      }

      // 混合搜索模式 (Hybrid Search using RRF)
      return await _retrieveHybridIsolated(
        query,
        aliyunKey,
        limit,
        filterDocumentIds,
        supportDir.path,
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'RAG retrieval failed',
        error: e,
        stackTrace: stackTrace,
        details: 'query=$query',
      );
      // 网络失败或其它情况，兜底使用纯本地 BM25 检索，确保不影响核心会话
      try {
        final supportDir = await getApplicationSupportDirectory();
        return await _retrieveBm25Isolated(
          query,
          limit,
          filterDocumentIds,
          supportDir.path,
        );
      } catch (ex) {
        return const [];
      }
    }
  }

  /// 使用后台 Isolate 运行 BM25 检索
  Future<List<RagChunk>> _retrieveBm25Isolated(
    String query,
    int limit,
    Set<String>? filterDocumentIds,
    String supportDirPath,
  ) async {
    final searchEngineJson = _searchEngine.toJson();
    searchEngineJson.remove('chunks');

    final List<dynamic> results = await compute(_bm25SearchTask, {
      'query': query,
      'limit': limit,
      'filterDocumentIds': filterDocumentIds?.toList(),
      'supportDirPath': supportDirPath,
      'searchEngineJson': searchEngineJson,
    });

    return results
        .map((m) => RagChunk.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  /// 使用后台 Isolate 运行 阿里云 DashScope Embedding 语义检索
  Future<List<RagChunk>> _retrieveVectorIsolated(
    String query,
    String apiKey,
    int limit,
    Set<String>? filterDocumentIds,
    String supportDirPath,
  ) async {
    final client = AliyunEmbeddingClient(apiKey: apiKey);
    final queryVectors = await client.getEmbeddings([query], textType: 'query');
    if (queryVectors.isEmpty) return const [];
    final queryVector = queryVectors.first;

    final List<String> targetDocIds =
        filterDocumentIds != null && filterDocumentIds.isNotEmpty
        ? filterDocumentIds.toList()
        : _documents.map((d) => d.id).toList();

    final List<dynamic> results = await compute(_vectorSearchTask, {
      'queryVector': queryVector,
      'targetDocIds': targetDocIds,
      'supportDirPath': supportDirPath,
      'limit': limit,
    });

    return results
        .map((m) => RagChunk.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  /// 使用后台 Isolate 运行 倒数排序融合 (RRF) 混合搜索
  Future<List<RagChunk>> _retrieveHybridIsolated(
    String query,
    String apiKey,
    int limit,
    Set<String>? filterDocumentIds,
    String supportDirPath,
  ) async {
    final client = AliyunEmbeddingClient(apiKey: apiKey);
    final queryVectors = await client.getEmbeddings([query], textType: 'query');
    if (queryVectors.isEmpty) return const [];
    final queryVector = queryVectors.first;

    final List<String> targetDocIds =
        filterDocumentIds != null && filterDocumentIds.isNotEmpty
        ? filterDocumentIds.toList()
        : _documents.map((d) => d.id).toList();

    final searchEngineJson = _searchEngine.toJson();
    searchEngineJson.remove('chunks');

    final List<dynamic> results = await compute(_hybridSearchTask, {
      'query': query,
      'queryVector': queryVector,
      'targetDocIds': targetDocIds,
      'supportDirPath': supportDirPath,
      'limit': limit,
      'searchEngineJson': searchEngineJson,
    });

    return results
        .map((m) => RagChunk.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  /// 保存元数据与轻量倒排索引状态至本地
  Future<void> _saveMetadataAndIndex(String supportDirPath) async {
    try {
      final metadataFile = File(p.join(supportDirPath, 'rag_metadata.json'));
      final searchEngineJson = _searchEngine.toJson();
      searchEngineJson.remove('chunks');

      final data = {
        'documents': _documents.map((doc) => doc.toJson()).toList(),
        'searchEngine': searchEngineJson,
      };
      await metadataFile.writeAsString(jsonEncode(data));
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'RAG save metadata and index failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}

/// 以下为后台 Isolate 计算任务 Top-level 函数，避免卡顿 UI 线程

Map<String, dynamic> _rebuildIndexTask(Map<String, dynamic> args) {
  final supportDirPath = args['supportDirPath'] as String;
  final docIds = (args['documentIds'] as List).cast<String>();
  final k1 = args['k1'] as double;
  final b = args['b'] as double;

  final engine = Bm25SearchEngine(k1: k1, b: b);
  for (final docId in docIds) {
    final file = File(p.join(supportDirPath, 'rag_doc_$docId.json'));
    if (file.existsSync()) {
      final content = file.readAsStringSync();
      final list = jsonDecode(content) as List;
      final chunks = list
          .map((item) => RagChunk.fromJson(item as Map<String, dynamic>))
          .toList();
      engine.addChunks(chunks);
    }
  }
  final json = engine.toJson();
  json.remove('chunks');
  return json;
}

List<Map<String, dynamic>> _bm25SearchTask(Map<String, dynamic> args) {
  final query = args['query'] as String;
  final limit = args['limit'] as int;
  final filterDocumentIds = (args['filterDocumentIds'] as List?)
      ?.cast<String>()
      .toSet();
  final supportDirPath = args['supportDirPath'] as String;
  final searchEngineJson = args['searchEngineJson'] as Map<String, dynamic>;

  final engine = Bm25SearchEngine();
  engine.loadFromJson(searchEngineJson);

  final queryTokens = engine.tokenize(query);
  final candidateDocIds = <String>{};
  for (final token in queryTokens) {
    final matches = engine.invertedIndex[token];
    if (matches != null) {
      for (final chunkId in matches.keys) {
        final docId = chunkId.split('_c').first;
        candidateDocIds.add(docId);
      }
    }
  }

  if (filterDocumentIds != null && filterDocumentIds.isNotEmpty) {
    candidateDocIds.retainAll(filterDocumentIds);
  }

  for (final docId in candidateDocIds) {
    final file = File(p.join(supportDirPath, 'rag_doc_$docId.json'));
    if (file.existsSync()) {
      final content = file.readAsStringSync();
      final list = jsonDecode(content) as List;
      for (final item in list) {
        final chunk = RagChunk.fromJson(item as Map<String, dynamic>);
        engine.chunks[chunk.id] = chunk;
      }
    }
  }

  final results = engine.search(query, limit: limit);
  return results.map((r) => r.chunk.toJson()).toList();
}

List<Map<String, dynamic>> _vectorSearchTask(Map<String, dynamic> args) {
  final queryVector = (args['queryVector'] as List).cast<double>();
  final targetDocIds = (args['targetDocIds'] as List).cast<String>();
  final supportDirPath = args['supportDirPath'] as String;
  final limit = args['limit'] as int;

  final candidates = <RagChunk>[];
  for (final docId in targetDocIds) {
    final file = File(p.join(supportDirPath, 'rag_doc_$docId.json'));
    if (file.existsSync()) {
      final content = file.readAsStringSync();
      final list = jsonDecode(content) as List;
      for (final item in list) {
        candidates.add(RagChunk.fromJson(item as Map<String, dynamic>));
      }
    }
  }

  final scoredList = <ScoredRagChunk>[];
  for (final chunk in candidates) {
    final chunkEmbedding = chunk.metadata['embedding'] as List<dynamic>?;
    if (chunkEmbedding == null || chunkEmbedding.isEmpty) continue;

    final vector = chunkEmbedding
        .map((val) => (val as num).toDouble())
        .toList();
    final score = VectorMath.dotProduct(queryVector, vector);
    scoredList.add(ScoredRagChunk(chunk: chunk, score: score));
  }

  scoredList.sort((a, b) => b.score.compareTo(a.score));
  return scoredList.map((sc) => sc.chunk.toJson()).take(limit).toList();
}

List<Map<String, dynamic>> _hybridSearchTask(Map<String, dynamic> args) {
  final query = args['query'] as String;
  final queryVector = (args['queryVector'] as List).cast<double>();
  final targetDocIds = (args['targetDocIds'] as List).cast<String>();
  final supportDirPath = args['supportDirPath'] as String;
  final limit = args['limit'] as int;
  final searchEngineJson = args['searchEngineJson'] as Map<String, dynamic>;

  final engine = Bm25SearchEngine();
  engine.loadFromJson(searchEngineJson);

  final allChunksMap = <String, RagChunk>{};
  for (final docId in targetDocIds) {
    final file = File(p.join(supportDirPath, 'rag_doc_$docId.json'));
    if (file.existsSync()) {
      final content = file.readAsStringSync();
      final list = jsonDecode(content) as List;
      for (final item in list) {
        final chunk = RagChunk.fromJson(item as Map<String, dynamic>);
        engine.chunks[chunk.id] = chunk;
        allChunksMap[chunk.id] = chunk;
      }
    }
  }

  final bm25Results = engine.search(query, limit: limit * 4);
  final bm25Rank = bm25Results.map((c) => c.chunk.id).toList();

  final scoredList = <ScoredRagChunk>[];
  for (final chunk in allChunksMap.values) {
    final chunkEmbedding = chunk.metadata['embedding'] as List<dynamic>?;
    if (chunkEmbedding == null || chunkEmbedding.isEmpty) continue;

    final vector = chunkEmbedding
        .map((val) => (val as num).toDouble())
        .toList();
    final score = VectorMath.dotProduct(queryVector, vector);
    scoredList.add(ScoredRagChunk(chunk: chunk, score: score));
  }
  scoredList.sort((a, b) => b.score.compareTo(a.score));
  final vectorRank = scoredList
      .map((sc) => sc.chunk.id)
      .take(limit * 4)
      .toList();

  if (bm25Rank.isEmpty && vectorRank.isEmpty) return const [];

  final fusedIds = RrfMerger.merge(bm25Rank: bm25Rank, vectorRank: vectorRank);

  final result = <Map<String, dynamic>>[];
  for (final id in fusedIds) {
    final chunk = allChunksMap[id];
    if (chunk != null) {
      result.add(chunk.toJson());
      if (result.length >= limit) break;
    }
  }

  return result;
}
