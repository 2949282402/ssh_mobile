// RAG 检索算法和缓存读取协作。
//
// 该 Mixin 只承载 BM25、向量、Hybrid 检索以及索引缓存维护，避免把网络
// 检索和文档写入生命周期混在同一个 Service 文件中。它只能附着于
// RagService，因此不会形成跨 Feature 的隐式依赖。

part of 'rag_service.dart';

/// RAG Service 的检索与索引缓存实现。
mixin RagRetrievalMixin implements RagCapability {
  static const int maxRetrieveLimit = 50;

  RagRepository get _repository;
  RagSettingsPort get _settings;
  RagLoggerPort get _logger;
  RagCacheStore get _cacheStore;
  RagEmbeddingFactory get _embeddingClientFactory;
  Bm25SearchEngine get _searchEngine;
  List<RagDocumentMetadata> get _documents;
  Map<String, RagCacheMetadata> get _cacheEntries;

  Future<void> init({bool force = false});

  Map<String, List<RagChunk>> _lastLoadedChunks = {};

  /// 检索最相关的文档块，向量服务失败时自动回退到本地 BM25。
  @override
  Future<List<RagChunk>> retrieve(
    String query, {
    int limit = 3,
    Set<String>? filterDocumentIds,
    String? searchMode,
    String? aliyunApiKey,
  }) async {
    await init();
    if (_documents.isEmpty || query.trim().isEmpty) return const [];
    final effectiveLimit = limit.clamp(1, maxRetrieveLimit);

    try {
      final mode = searchMode == null
          ? _settings.searchMode
          : RagSearchMode.fromValue(searchMode);
      final apiKey = mode == RagSearchMode.bm25
          ? ''
          : (aliyunApiKey ?? await _settings.getAliyunApiKey() ?? '').trim();
      if (mode == RagSearchMode.bm25 || apiKey.isEmpty) {
        return await _retrieveBm25(query, effectiveLimit, filterDocumentIds);
      }
      final chunks = await _readChunksForDocuments(
        _targetDocumentIds(filterDocumentIds),
      );
      if (mode == RagSearchMode.vector) {
        return _retrieveVector(query, apiKey, effectiveLimit, chunks);
      }
      return _retrieveHybrid(query, apiKey, effectiveLimit, chunks);
    } catch (error, stackTrace) {
      _logger.error(
        'RAG retrieval failed',
        error: error,
        stackTrace: stackTrace,
        details: 'queryLength=${query.length}',
      );
      try {
        return await _retrieveBm25(query, effectiveLimit, filterDocumentIds);
      } catch (_) {
        return const [];
      }
    }
  }

  Future<List<RagChunk>> _retrieveBm25(
    String query,
    int limit,
    Set<String>? filterDocumentIds,
  ) async {
    final targetIds = _targetDocumentIds(filterDocumentIds);
    final candidateIds = <String>{};
    for (final token in _searchEngine.tokenize(query)) {
      final matches = _searchEngine.invertedIndex[token];
      if (matches == null) continue;
      candidateIds.addAll(matches.keys.map((id) => id.split('_c').first));
    }
    candidateIds.retainAll(targetIds);
    await _readChunksForDocuments(candidateIds);
    return _searchLoadedChunks(query, limit, candidateIds);
  }

  List<RagChunk> _searchLoadedChunks(String query, int limit, Set<String> ids) {
    final loaded = <RagChunk>[];
    for (final entry in _lastLoadedChunks.entries) {
      if (ids.contains(entry.key)) loaded.addAll(entry.value);
    }
    final engine = Bm25SearchEngine()..addChunks(loaded);
    return engine
        .search(query, limit: limit)
        .map((item) => item.chunk)
        .toList();
  }

  Future<List<RagChunk>> _retrieveVector(
    String query,
    String apiKey,
    int limit,
    Map<String, List<RagChunk>> chunksByDocument,
  ) async {
    final queryVectors = await _queryVectorsAsync(query, apiKey);
    if (queryVectors.isEmpty) return const [];
    final queryVector = queryVectors.first;
    final scored = <ScoredRagChunk>[];
    for (final chunks in chunksByDocument.values) {
      for (final chunk in chunks) {
        final embedding = _readEmbedding(chunk);
        if (embedding == null) continue;
        scored.add(
          ScoredRagChunk(
            chunk: chunk,
            score: VectorMath.dotProduct(queryVector, embedding),
          ),
        );
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((item) => item.chunk).toList();
  }

  Future<List<RagChunk>> _retrieveHybrid(
    String query,
    String apiKey,
    int limit,
    Map<String, List<RagChunk>> chunksByDocument,
  ) async {
    final allChunks = chunksByDocument.values
        .expand((chunks) => chunks)
        .toList();
    final engine = Bm25SearchEngine()..addChunks(allChunks);
    final bm25Rank = engine
        .search(query, limit: limit * 4)
        .map((item) => item.chunk.id)
        .toList();
    final queryVectors = await _queryVectorsAsync(query, apiKey);
    if (queryVectors.isEmpty) {
      return engine
          .search(query, limit: limit)
          .map((item) => item.chunk)
          .toList();
    }
    final queryVector = queryVectors.first;
    final scored = <ScoredRagChunk>[];
    for (final chunk in allChunks) {
      final embedding = _readEmbedding(chunk);
      if (embedding == null) continue;
      scored.add(
        ScoredRagChunk(
          chunk: chunk,
          score: VectorMath.dotProduct(queryVector, embedding),
        ),
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    final vectorRank = scored
        .take(limit * 4)
        .map((item) => item.chunk.id)
        .toList();
    final byId = {for (final chunk in allChunks) chunk.id: chunk};
    final fused = RrfMerger.merge(bm25Rank: bm25Rank, vectorRank: vectorRank);
    final result = <RagChunk>[];
    for (final id in fused) {
      final chunk = byId[id];
      if (chunk != null) result.add(chunk);
      if (result.length >= limit) break;
    }
    return result;
  }

  List<double>? _readEmbedding(RagChunk chunk) {
    final raw = chunk.metadata['embedding'];
    if (raw is! List) return null;
    final embedding = [
      for (final value in raw)
        if (value is num) value.toDouble(),
    ];
    return embedding.isEmpty ? null : embedding;
  }

  Future<List<List<double>>> _queryVectorsAsync(String query, String apiKey) {
    final client = _embeddingClientFactory(apiKey: apiKey, logger: _logger);
    return client.getEmbeddings([query], textType: 'query');
  }

  Future<Map<String, List<RagChunk>>> _readChunksForDocuments(
    Set<String> documentIds,
  ) async {
    _lastLoadedChunks = {};
    for (final documentId in documentIds) {
      final entry = _cacheEntries[documentId];
      if (entry == null) continue;
      final chunks = await _cacheStore.read(entry);
      if (chunks.isEmpty) continue;
      _lastLoadedChunks[documentId] = chunks;
      final touched = entry.copyWith(lastAccessedAt: DateTime.now());
      _cacheEntries[documentId] = touched;
      await _repository.updateCacheEntry(touched);
    }
    return _lastLoadedChunks;
  }

  Set<String> _targetDocumentIds(Set<String>? filterDocumentIds) {
    final all = _documents.map((document) => document.id).toSet();
    if (filterDocumentIds == null || filterDocumentIds.isEmpty) return all;
    return all.intersection(filterDocumentIds);
  }

  Future<void> _rebuildIndexFromCache() async {
    final chunks = <RagChunk>[];
    for (final entry in _cacheEntries.values) {
      chunks.addAll(await _cacheStore.read(entry));
    }
    _searchEngine
      ..clear()
      ..addChunks(chunks)
      ..chunks.clear();
  }

  Future<bool> _evictExpiredAndOversized() async {
    var changed = false;
    final now = DateTime.now();
    final entries = _cacheEntries.values.toList();
    for (final entry in entries) {
      if (entry.expiresAt.isBefore(now) || !await _cacheStore.exists(entry)) {
        await _cacheStore.delete(entry);
        _cacheEntries.remove(entry.documentId);
        changed = true;
      }
    }

    var totalBytes = _cacheEntries.values.fold<int>(
      0,
      (total, entry) => total + entry.sizeBytes,
    );
    final ordered = _cacheEntries.values.toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));
    for (final entry in ordered) {
      if (totalBytes <= _cacheStore.policy.maxTotalBytes) break;
      await _cacheStore.delete(entry);
      _cacheEntries.remove(entry.documentId);
      totalBytes -= entry.sizeBytes;
      changed = true;
    }
    return changed;
  }
}
