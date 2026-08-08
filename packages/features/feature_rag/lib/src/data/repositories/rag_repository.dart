// RAG 元数据和索引 Repository。
//
// Repository 永远不接收文档正文；文档块和向量由 RagCacheStore 管理，避免
// Repository 成为无界内存/数据库缓存。

import 'dart:convert';

import '../database/rag_database.dart' as db;
import '../../domain/rag_models.dart';

/// RAG Module 的持久化契约。
abstract interface class RagRepository {
  Future<RagRepositorySnapshot> loadSnapshot();

  Future<void> saveState({
    required List<RagDocumentMetadata> documents,
    required RagIndexMetadata index,
    required List<RagCacheMetadata> cacheEntries,
  });

  Future<void> updateCacheEntry(RagCacheMetadata entry);

  Future<void> deleteCacheEntry(String documentId);
}

/// Drift 实现；数据库关闭责任归 RagModule。
final class DriftRagRepository implements RagRepository {
  const DriftRagRepository(this._database);

  final db.RagDatabase _database;

  @override
  Future<RagRepositorySnapshot> loadSnapshot() async {
    final rows = await _database.ragDao.loadDocumentRows();
    final indexRow = await _database.ragDao.loadIndexRow();
    final cacheRows = await _database.ragDao.loadCacheRows();

    return RagRepositorySnapshot(
      documents: [
        for (final row in rows)
          RagDocumentMetadata(
            id: row.id,
            name: row.name,
            mimeType: row.mimeType,
            sizeBytes: row.sizeBytes,
            uploadedAt: row.uploadedAt,
            chunkCount: row.chunkCount,
          ),
      ],
      index: indexRow == null
          ? null
          : RagIndexMetadata(
              totalDocs: indexRow.totalDocs,
              avgDocLength: indexRow.avgDocLength,
              docLengths: _decodeIntMap(indexRow.docLengthsJson),
              invertedIndex: _decodeNestedIntMap(indexRow.invertedIndexJson),
              updatedAt: indexRow.updatedAt,
            ),
      cacheEntries: [
        for (final row in cacheRows)
          RagCacheMetadata(
            documentId: row.documentId,
            fileName: row.fileName,
            sizeBytes: row.sizeBytes,
            createdAt: row.createdAt,
            lastAccessedAt: row.lastAccessedAt,
            expiresAt: row.expiresAt,
          ),
      ],
    );
  }

  @override
  Future<void> saveState({
    required List<RagDocumentMetadata> documents,
    required RagIndexMetadata index,
    required List<RagCacheMetadata> cacheEntries,
  }) {
    return _database.ragDao.saveState(
      documents: documents,
      index: index,
      cacheEntries: cacheEntries,
    );
  }

  @override
  Future<void> updateCacheEntry(RagCacheMetadata entry) =>
      _database.ragDao.updateCacheEntry(entry);

  @override
  Future<void> deleteCacheEntry(String documentId) =>
      _database.ragDao.deleteCacheEntry(documentId);

  static Map<String, int> _decodeIntMap(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is num)
          entry.key.toString(): (entry.value as num).toInt(),
    };
  }

  static Map<String, Map<String, int>> _decodeNestedIntMap(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return {};
    final result = <String, Map<String, int>>{};
    for (final entry in decoded.entries) {
      if (entry.value is! Map) continue;
      result[entry.key.toString()] = {
        for (final item in (entry.value as Map).entries)
          if (item.value is num)
            item.key.toString(): (item.value as num).toInt(),
      };
    }
    return result;
  }
}
