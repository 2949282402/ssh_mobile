// RAG Repository 数据边界测试。
//
// 验证 rag.db 只保存元数据、索引统计和缓存清单，不把文档正文写入数据库。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feature_rag/feature_rag.dart';

void main() {
  test(
    'repository persists metadata and index without document content',
    () async {
      final database = RagDatabase.forTesting(NativeDatabase.memory());
      final repository = DriftRagRepository(database);
      final uploadedAt = DateTime.utc(2026, 8, 8);
      final cache = RagCacheMetadata(
        documentId: 'doc-1',
        fileName: 'rag_doc_doc-1.json',
        sizeBytes: 123,
        createdAt: uploadedAt,
        lastAccessedAt: uploadedAt,
        expiresAt: uploadedAt.add(const Duration(days: 30)),
      );

      await repository.saveState(
        documents: [
          RagDocumentMetadata(
            id: 'doc-1',
            name: 'ops.md',
            mimeType: 'text/markdown',
            sizeBytes: 42,
            uploadedAt: uploadedAt,
            chunkCount: 1,
          ),
        ],
        index: RagIndexMetadata(
          totalDocs: 1,
          avgDocLength: 2,
          docLengths: const {'doc-1_c0': 2},
          invertedIndex: const {
            'restart': {'doc-1_c0': 1},
          },
          updatedAt: uploadedAt,
        ),
        cacheEntries: [cache],
      );

      final snapshot = await repository.loadSnapshot();
      expect(snapshot.documents.single.name, 'ops.md');
      expect(snapshot.index?.invertedIndex['restart'], {'doc-1_c0': 1});
      expect(snapshot.cacheEntries.single.sizeBytes, 123);

      final rows = await database
          .customSelect('SELECT * FROM rag_index_metadata_table')
          .get();
      expect(
        rows.single.data.values.any((value) => value == 'secret document text'),
        isFalse,
      );

      await database.dispose();
    },
  );
}
