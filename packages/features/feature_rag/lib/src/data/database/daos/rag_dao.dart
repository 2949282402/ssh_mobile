// RAG 数据库 DAO。
//
// DAO 只负责 Drift 行与事务，不解析正文或执行检索；Repository 负责把行
// 转换为领域模型并保持缓存清单与索引快照的一致性。

part of '../rag_database.dart';

@DriftAccessor(tables: [RagDocuments, RagIndexMetadataTable, RagCacheEntries])
class RagDao extends DatabaseAccessor<RagDatabase> with _$RagDaoMixin {
  RagDao(super.attachedDatabase);

  Future<List<RagDocument>> loadDocumentRows() => select(ragDocuments).get();

  Future<RagIndexMetadataTableData?> loadIndexRow() =>
      select(ragIndexMetadataTable).getSingleOrNull();

  Future<List<RagCacheEntry>> loadCacheRows() => select(ragCacheEntries).get();

  /// 在一个事务中保存元数据、索引快照和缓存清单。
  Future<void> saveState({
    required List<RagDocumentMetadata> documents,
    required RagIndexMetadata index,
    required List<RagCacheMetadata> cacheEntries,
  }) async {
    await transaction(() async {
      await delete(ragCacheEntries).go();
      await delete(ragDocuments).go();
      await delete(ragIndexMetadataTable).go();

      if (documents.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(
            ragDocuments,
            documents
                .map(
                  (document) => RagDocumentsCompanion.insert(
                    id: document.id,
                    name: document.name,
                    mimeType: document.mimeType,
                    sizeBytes: document.sizeBytes,
                    uploadedAt: document.uploadedAt,
                    chunkCount: document.chunkCount,
                  ),
                )
                .toList(),
          );
        });
      }

      await into(ragIndexMetadataTable).insert(
        RagIndexMetadataTableCompanion.insert(
          id: 'current',
          totalDocs: index.totalDocs,
          avgDocLength: index.avgDocLength,
          docLengthsJson: jsonEncode(index.docLengths),
          invertedIndexJson: jsonEncode(index.invertedIndex),
          updatedAt: index.updatedAt,
        ),
      );

      if (cacheEntries.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(
            ragCacheEntries,
            cacheEntries
                .map(
                  (entry) => RagCacheEntriesCompanion.insert(
                    documentId: entry.documentId,
                    fileName: entry.fileName,
                    sizeBytes: entry.sizeBytes,
                    createdAt: entry.createdAt,
                    lastAccessedAt: entry.lastAccessedAt,
                    expiresAt: entry.expiresAt,
                  ),
                )
                .toList(),
          );
        });
      }
    });
  }

  Future<void> updateCacheEntry(RagCacheMetadata entry) {
    return update(ragCacheEntries).replace(
      RagCacheEntriesCompanion(
        documentId: Value(entry.documentId),
        fileName: Value(entry.fileName),
        sizeBytes: Value(entry.sizeBytes),
        createdAt: Value(entry.createdAt),
        lastAccessedAt: Value(entry.lastAccessedAt),
        expiresAt: Value(entry.expiresAt),
      ),
    );
  }

  Future<void> deleteCacheEntry(String documentId) => (delete(
    ragCacheEntries,
  )..where((row) => row.documentId.equals(documentId))).go();
}
