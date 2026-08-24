// RAG 应用服务。
//
// Service 负责文档解析、分块、Embedding、索引和检索编排；元数据写入
// RagRepository，正文/向量写入 RagCacheStore。这样数据库、缓存和 AI 能力
// 的生命周期都能由 RagModule 明确管理。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/cache/rag_cache_store.dart';
import '../data/repositories/rag_repository.dart';
import '../domain/rag_models.dart';
import '../domain/rag_ports.dart';
import '../processing/bm25_search.dart';
import '../processing/pdf_text_extractor.dart';
import '../processing/text_chunker.dart';
import '../processing/vector_search_utils.dart';

part 'rag_retrieval.dart';

/// RAG Service 的业务边界和并发安全实现。
final class RagService extends ChangeNotifier
    with RagRetrievalMixin
    implements RagCapability {
  static const int embeddingBatchSize = 20;
  static const int maxExtractedTextChars = 2 * 1024 * 1024;
  static const int maxChunksPerDocument = 4096;
  static const int maxEmbeddingInputChars = 2 * 1024 * 1024;

  RagService({
    required this._repository,
    required this._settings,
    required this._logger,
    RagCacheStore? cacheStore,
    RagEmbeddingFactory? embeddingClientFactory,
  }) : _cacheStore = cacheStore ?? RagCacheStore(),
       _embeddingClientFactory =
           embeddingClientFactory ??
           (({required String apiKey, RagLoggerPort? logger}) =>
               AliyunEmbeddingClient(apiKey: apiKey, logger: logger));

  @override
  final RagRepository _repository;
  @override
  final RagSettingsPort _settings;
  @override
  final RagLoggerPort _logger;
  @override
  final RagCacheStore _cacheStore;
  @override
  final RagEmbeddingFactory _embeddingClientFactory;
  @override
  final Bm25SearchEngine _searchEngine = Bm25SearchEngine();
  @override
  final List<RagDocumentMetadata> _documents = [];
  @override
  final Map<String, RagCacheMetadata> _cacheEntries = {};

  Future<void>? _initFuture;
  bool _isLoading = false;
  bool _isInitialized = false;
  bool _disposed = false;
  bool _notifierDisposed = false;
  final Set<Future<void>> _operations = <Future<void>>{};
  Future<void>? _closeFuture;

  /// 当前已保存的文档元数据；列表副本防止 UI 绕过 Service 修改状态。
  List<RagDocumentMetadata> get documents => List.unmodifiable(_documents);

  bool get isLoading => _isLoading;

  bool get isInitialized => _isInitialized;

  /// 幂等初始化数据库快照；force 只重新加载当前 rag.db，不读取旧文件。
  @override
  Future<void> init({bool force = false}) {
    _ensureNotDisposed();
    if (force) {
      _initFuture = null;
      _isInitialized = false;
    }
    return _initFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    _setLoading(true);
    try {
      final snapshot = await _repository.loadSnapshot();
      _documents
        ..clear()
        ..addAll(snapshot.documents);
      _cacheEntries
        ..clear()
        ..addEntries(
          snapshot.cacheEntries.map(
            (entry) => MapEntry(entry.documentId, entry),
          ),
        );

      _searchEngine.clear();
      final index = snapshot.index;
      if (index != null) {
        _searchEngine.loadFromJson({...index.toJson(), 'chunks': const {}});
      }

      final cacheChanged = await _evictExpiredAndOversized();
      if (cacheChanged || index == null) {
        await _rebuildIndexFromCache();
        await _persistState();
      }
      _isInitialized = true;
      _logger.info(
        'RAG service initialized',
        details: 'loadedDocs=${_documents.length}',
      );
    } catch (error, stackTrace) {
      _logger.error(
        'RAG service initialization failed',
        error: error,
        stackTrace: stackTrace,
      );
      _isInitialized = false;
      _initFuture = null;
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  /// 解析并索引文档；大文件和过大的序列化缓存会在边界处拒绝。
  Future<RagDocumentMetadata> addDocument({
    required String name,
    required List<int> bytes,
    required String mimeType,
  }) => _trackOperation(
    () => _addDocument(name: name, bytes: bytes, mimeType: mimeType),
  );

  Future<RagDocumentMetadata> _addDocument({
    required String name,
    required List<int> bytes,
    required String mimeType,
  }) async {
    await init();
    _ensureNotDisposed();
    if (bytes.length > _cacheStore.policy.maxSourceBytes) {
      throw ArgumentError('文档大小超过 RAG 缓存允许的上限。');
    }

    _setLoading(true);
    final documentId = const Uuid().v4();
    RagCacheMetadata? cacheEntry;
    try {
      final text = _extractText(name: name, bytes: bytes, mimeType: mimeType);
      if (text.trim().isEmpty) {
        throw ArgumentError('未在文档中提取到有效文本内容。');
      }
      if (text.length > maxExtractedTextChars) {
        throw ArgumentError('文档提取文本超过 RAG 允许的上限。');
      }

      final chunks = TextChunker.split(
        text: text,
        documentId: documentId,
        documentName: name,
        chunkSize: 600,
        chunkOverlap: 120,
      );
      if (chunks.isEmpty) throw StateError('文本切块失败。');
      if (chunks.length > maxChunksPerDocument) {
        throw ArgumentError('文档分块数量超过 RAG 允许的上限。');
      }

      await _attachEmbeddings(chunks);
      cacheEntry = await _cacheStore.write(
        documentId: documentId,
        chunks: chunks,
      );
      final metadata = RagDocumentMetadata(
        id: documentId,
        name: name,
        mimeType: mimeType,
        sizeBytes: bytes.length,
        uploadedAt: DateTime.now(),
        chunkCount: chunks.length,
      );

      _documents.add(metadata);
      _cacheEntries[documentId] = cacheEntry;
      _searchEngine.addChunks(chunks);
      _searchEngine.chunks.clear();
      await _persistState();
      final cacheChanged = await _evictExpiredAndOversized();
      if (cacheChanged) {
        await _rebuildIndexFromCache();
        await _persistState();
      }

      _logger.info(
        'RAG document added successfully',
        details: 'docId=$documentId chunks=${chunks.length}',
      );
      return metadata;
    } catch (error, stackTrace) {
      if (cacheEntry != null) await _cacheStore.delete(cacheEntry);
      _documents.removeWhere((document) => document.id == documentId);
      _cacheEntries.remove(documentId);
      await _rebuildIndexFromCache();
      _logger.error(
        'RAG add document failed',
        error: error,
        stackTrace: stackTrace,
        details: 'docId=$documentId',
      );
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  /// 删除文档、缓存和对应索引；操作重复执行安全。
  Future<void> deleteDocument(String documentId) =>
      _trackOperation(() => _deleteDocument(documentId));

  Future<void> _deleteDocument(String documentId) async {
    await init();
    _ensureNotDisposed();
    _setLoading(true);
    try {
      final entry = _cacheEntries.remove(documentId);
      if (entry != null) await _cacheStore.delete(entry);
      _documents.removeWhere((document) => document.id == documentId);
      await _rebuildIndexFromCache();
      await _persistState();
      _logger.info(
        'RAG document deleted successfully',
        details: 'docId=$documentId',
      );
    } catch (error, stackTrace) {
      _logger.error(
        'RAG delete document failed',
        error: error,
        stackTrace: stackTrace,
        details: 'docId=$documentId',
      );
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    _disposed = true;
    _initFuture = null;
    _documents.clear();
    _cacheEntries.clear();
    super.dispose();
  }

  /// Stops accepting new work and joins all cache/database/embedding
  /// operations before the Module closes rag.db.
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    _disposed = true;
    final initializing = _initFuture;
    if (initializing != null) {
      try {
        await initializing;
      } catch (_) {
        // The initialization caller retains its original failure.
      }
    }
    while (_operations.isNotEmpty) {
      await Future.wait<void>(List.of(_operations));
    }
    dispose();
  }

  @override
  Future<T> _trackOperation<T>(Future<T> Function() action) {
    _ensureNotDisposed();
    final operation = action();
    late final Future<void> barrier;
    barrier = operation
        .then<void>((_) {}, onError: (_, _) {})
        .whenComplete(() => _operations.remove(barrier));
    _operations.add(barrier);
    return operation;
  }

  String _extractText({
    required String name,
    required List<int> bytes,
    required String mimeType,
  }) {
    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.pdf') || mimeType == 'application/pdf') {
      return PdfTextExtractor.extractText(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<void> _attachEmbeddings(List<RagChunk> chunks) async {
    final apiKey = (await _settings.getAliyunApiKey() ?? '').trim();
    if (apiKey.isEmpty) return;
    final embeddingChars = chunks.fold<int>(
      0,
      (total, chunk) => total + chunk.text.length,
    );
    if (embeddingChars > maxEmbeddingInputChars) {
      throw ArgumentError('Embedding 输入超过 RAG 允许的上限。');
    }

    try {
      final client = _embeddingClientFactory(apiKey: apiKey, logger: _logger);
      final texts = chunks.map((chunk) => chunk.text).toList();
      final embeddings = <List<double>>[];
      for (var start = 0; start < texts.length; start += embeddingBatchSize) {
        final end = (start + embeddingBatchSize).clamp(0, texts.length);
        embeddings.addAll(
          await client.getEmbeddings(
            texts.sublist(start, end),
            textType: 'document',
          ),
        );
      }
      for (
        var index = 0;
        index < chunks.length && index < embeddings.length;
        index++
      ) {
        final embedding = embeddings[index];
        if (embedding.isEmpty) continue;
        final chunk = chunks[index];
        chunks[index] = RagChunk(
          id: chunk.id,
          documentId: chunk.documentId,
          documentName: chunk.documentName,
          text: chunk.text,
          pageNumber: chunk.pageNumber,
          charStartIndex: chunk.charStartIndex,
          charEndIndex: chunk.charEndIndex,
          metadata: {...chunk.metadata, 'embedding': embedding},
        );
      }
    } catch (error, stackTrace) {
      _logger.warning(
        'RAG embedding generation failed; falling back to BM25',
        details: '$error',
      );
      _logger.error(
        'RAG embedding diagnostic',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _persistState() => _repository.saveState(
    documents: _documents,
    index: _indexMetadata(),
    cacheEntries: _cacheEntries.values.toList(),
  );

  RagIndexMetadata _indexMetadata() => RagIndexMetadata(
    totalDocs: _searchEngine.totalDocs,
    avgDocLength: _searchEngine.avgDocLength,
    docLengths: Map<String, int>.from(_searchEngine.docLengths),
    invertedIndex: {
      for (final entry in _searchEngine.invertedIndex.entries)
        entry.key: Map<String, int>.from(entry.value),
    },
    updatedAt: DateTime.now(),
  );

  void _setLoading(bool value) {
    if (_disposed) return;
    _isLoading = value;
    notifyListeners();
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('RagService has been disposed.');
  }
}
