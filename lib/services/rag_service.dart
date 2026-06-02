import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
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
      uploadedAt: DateTime.tryParse(json['uploadedAt'] as String? ?? '') ??
          DateTime.now(),
      chunkCount: json['chunkCount'] as int? ?? 0,
    );
  }
}

class RagService extends ChangeNotifier {
  final StorageService storageService;
  final List<RagDocumentMetadata> _documents = [];
  final Map<String, List<RagChunk>> _documentChunks = {};
  final Bm25SearchEngine _searchEngine = Bm25SearchEngine();
  bool _isLoading = false;
  bool _isInitialized = false;

  RagService({required this.storageService});

  List<RagDocumentMetadata> get documents => List.unmodifiable(_documents);
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;

  /// 初始化 RAG 服务，从本地持久化加载索引及文档元数据
  Future<void> init() async {
    if (_isInitialized) return;
    _isLoading = true;
    notifyListeners();

    try {
      final file = await _getDatabaseFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;

        // 1. 加载文档元数据
        final rawDocs = json['documents'] as List? ?? [];
        _documents.clear();
        for (final docJson in rawDocs) {
          if (docJson is Map<String, dynamic>) {
            _documents.add(RagDocumentMetadata.fromJson(docJson));
          }
        }

        // 2. 加载文档分块
        final rawChunks = json['documentChunks'] as Map<String, dynamic>? ?? {};
        _documentChunks.clear();
        rawChunks.forEach((docId, list) {
          if (list is List) {
            _documentChunks[docId] = list
                .map((item) => RagChunk.fromJson(item as Map<String, dynamic>))
                .toList();
          }
        });

        // 3. 反序列化搜索引擎索引
        final searchJson = json['searchEngine'] as Map<String, dynamic>?;
        if (searchJson != null) {
          _searchEngine.loadFromJson(searchJson);
        } else {
          // 如果索引为空，按分块重建索引
          _rebuildSearchEngine();
        }

        AppLogService.instance.info(
          'RAG service initialized',
          details:
              'loadedDocs=${_documents.length} loadedChunks=${_searchEngine.totalDocs}',
        );
      }
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

  /// 添加一个新文档，对其进行解析、分块、索引并持久化
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
            final batchEmbeddings =
                await client.getEmbeddings(batch, textType: 'document');
            embeddings.addAll(batchEmbeddings);
          }

          // 将生成的语义向量写入分块的 metadata 中
          for (var i = 0; i < chunks.length; i++) {
            if (i < embeddings.length) {
              chunks[i].metadata['embedding'] = embeddings[i];
            }
          }
          AppLogService.instance
              .info('RAG: Generated embeddings successfully via Aliyun');
        } catch (e) {
          AppLogService.instance.warning(
              'RAG: Failed to generate vectors via Aliyun: $e. Falling back to pure BM25 index.');
        }
      }

      // 3. 保存分块到内存和搜索引擎
      _documentChunks[docId] = chunks;
      _searchEngine.addChunks(chunks);

      // 4. 创建元数据
      final metadata = RagDocumentMetadata(
        id: docId,
        name: name,
        mimeType: mimeType,
        sizeBytes: bytes.length,
        uploadedAt: DateTime.now(),
        chunkCount: chunks.length,
      );

      _documents.add(metadata);

      // 5. 持久化数据
      await _saveDatabase();

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

  /// 删除指定文档及相关的所有索引分块并持久化
  Future<void> deleteDocument(String documentId) async {
    await init();
    _isLoading = true;
    notifyListeners();

    try {
      _documents.removeWhere((doc) => doc.id == documentId);
      _documentChunks.remove(documentId);

      // BM25 搜索引擎做重建比较省心且避免脏索引
      _rebuildSearchEngine();

      await _saveDatabase();

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
  }) async {
    await init();
    if (_documents.isEmpty || query.trim().isEmpty) return const [];

    try {
      final prefs = await SharedPreferences.getInstance();
      final searchMode = prefs.getString('rag_search_mode') ?? 'bm25';
      final aliyunKey = await storageService.getAliyunApiKey();

      // 如果选了向量/混合搜索，但没有配 Aliyun 密钥，则回退为 BM25 搜索
      if (searchMode == 'bm25' || aliyunKey == null || aliyunKey.isEmpty) {
        return _retrieveBm25(query, limit, filterDocumentIds);
      }

      if (searchMode == 'vector') {
        return await _retrieveVector(
            query, aliyunKey, limit, filterDocumentIds);
      }

      // 混合搜索模式 (Hybrid Search using RRF)
      return await _retrieveHybrid(query, aliyunKey, limit, filterDocumentIds);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'RAG retrieval failed',
        error: e,
        stackTrace: stackTrace,
        details: 'query=$query',
      );
      // 网络失败或其它情况，兜底使用纯本地 BM25 检索，确保不影响核心会话
      return _retrieveBm25(query, limit, filterDocumentIds);
    }
  }

  /// 纯本地 BM25 关键词检索
  List<RagChunk> _retrieveBm25(
      String query, int limit, Set<String>? filterDocumentIds) {
    final searchLimit =
        filterDocumentIds != null && filterDocumentIds.isNotEmpty
            ? limit * 3
            : limit;

    final results = _searchEngine.search(query, limit: searchLimit);
    final filtered = <RagChunk>[];
    for (final scored in results) {
      if (filterDocumentIds == null ||
          filterDocumentIds.isEmpty ||
          filterDocumentIds.contains(scored.chunk.documentId)) {
        filtered.add(scored.chunk);
        if (filtered.length >= limit) break;
      }
    }
    return filtered;
  }

  /// 阿里云 DashScope Embedding 语义检索
  Future<List<RagChunk>> _retrieveVector(
    String query,
    String apiKey,
    int limit,
    Set<String>? filterDocumentIds,
  ) async {
    final client = AliyunEmbeddingClient(apiKey: apiKey);
    final queryVectors = await client.getEmbeddings([query], textType: 'query');
    if (queryVectors.isEmpty) return const [];
    final queryVector = queryVectors.first;

    // 收集所有可供计算的候选分块
    final candidates = <RagChunk>[];
    if (filterDocumentIds != null && filterDocumentIds.isNotEmpty) {
      for (final docId in filterDocumentIds) {
        final docChunks = _documentChunks[docId];
        if (docChunks != null) candidates.addAll(docChunks);
      }
    } else {
      for (final docChunks in _documentChunks.values) {
        candidates.addAll(docChunks);
      }
    }

    // 计算余弦相似度（点积）并打分排序
    final scoredList = <ScoredRagChunk>[];
    for (final chunk in candidates) {
      final chunkEmbedding = chunk.metadata['embedding'] as List<dynamic>?;
      if (chunkEmbedding == null || chunkEmbedding.isEmpty) continue;

      // 转换为双精度浮点数
      final vector =
          chunkEmbedding.map((val) => (val as num).toDouble()).toList();
      final score = VectorMath.dotProduct(queryVector, vector);
      scoredList.add(ScoredRagChunk(chunk: chunk, score: score));
    }

    scoredList.sort((a, b) => b.score.compareTo(a.score));
    return scoredList.map((sc) => sc.chunk).take(limit).toList();
  }

  /// 倒数排序融合 (RRF) 混合搜索
  Future<List<RagChunk>> _retrieveHybrid(
    String query,
    String apiKey,
    int limit,
    Set<String>? filterDocumentIds,
  ) async {
    // 1. 获取 BM25 的排名结果（多获取一些供 RRF 进行深层排序融合）
    final bm25Chunks = _retrieveBm25(query, limit * 4, filterDocumentIds);
    final bm25Rank = bm25Chunks.map((c) => c.id).toList();

    // 2. 获取向量检索的排名结果
    final vectorChunks =
        await _retrieveVector(query, apiKey, limit * 4, filterDocumentIds);
    final vectorRank = vectorChunks.map((c) => c.id).toList();

    if (bm25Rank.isEmpty && vectorRank.isEmpty) return const [];

    // 3. 使用 RRF 合并两种排名的得分
    final fusedIds =
        RrfMerger.merge(bm25Rank: bm25Rank, vectorRank: vectorRank);

    // 4. 根据融合排名重组实体，取 Top-K
    final allChunksMap = <String, RagChunk>{};
    for (final c in bm25Chunks) {
      allChunksMap[c.id] = c;
    }
    for (final c in vectorChunks) {
      allChunksMap[c.id] = c;
    }

    final result = <RagChunk>[];
    for (final id in fusedIds) {
      final chunk = allChunksMap[id];
      if (chunk != null) {
        result.add(chunk);
        if (result.length >= limit) break;
      }
    }

    return result;
  }

  /// 一键重新构建所有搜索引擎的倒排索引
  void _rebuildSearchEngine() {
    _searchEngine.clear();
    for (final chunks in _documentChunks.values) {
      _searchEngine.addChunks(chunks);
    }
  }

  /// 获取本地持久化数据库文件
  Future<File> _getDatabaseFile() async {
    final supportDir = await getApplicationSupportDirectory();
    return File(p.join(supportDir.path, 'rag_database.json'));
  }

  /// 保存元数据与倒排索引至本地
  Future<void> _saveDatabase() async {
    try {
      final file = await _getDatabaseFile();
      final data = {
        'documents': _documents.map((doc) => doc.toJson()).toList(),
        'documentChunks': _documentChunks
            .map((k, v) => MapEntry(k, v.map((c) => c.toJson()).toList())),
        'searchEngine': _searchEngine.toJson(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'RAG save database failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}
