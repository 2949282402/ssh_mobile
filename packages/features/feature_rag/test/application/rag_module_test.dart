// RAG Module 和 Service 生命周期测试。
//
// 使用内存 Drift 和临时目录验证数据库/缓存 Owner、BM25 检索和幂等释放。

import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feature_rag/feature_rag.dart';

import '../fakes/rag_test_fakes.dart';

void main() {
  test('module owns rag database and service lifecycle', () async {
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'rag-module-test-',
    );
    final settings = FakeRagSettings();
    final logger = RecordingRagLogger();
    final module = RagModule(
      databaseFactory: () => RagDatabase.forTesting(NativeDatabase.memory()),
      cacheStoreFactory: () =>
          RagCacheStore(directoryFactory: () async => cacheDirectory),
    );

    await module.register(
      ModuleContext.fromMap({RagSettingsPort: settings, RagLoggerPort: logger}),
    );
    await module.initialize();
    await module.activate();
    await module.service.init();

    final document = await module.service.addDocument(
      name: 'ops.txt',
      bytes: 'Use kubectl get pods to inspect the cluster.'.codeUnits,
      mimeType: 'text/plain',
    );
    expect(module.state, ModuleState.active);
    expect(module.service.documents.single.id, document.id);

    final results = await module.service.retrieve('kubectl get pods');
    expect(results, isNotEmpty);
    expect(results.first.documentName, 'ops.txt');

    await module.service.deleteDocument(document.id);
    expect(module.service.documents, isEmpty);
    expect(await module.service.retrieve('kubectl'), isEmpty);

    await module.dispose();
    await module.dispose();
    expect(module.state, ModuleState.disposed);
    settings.dispose();
    await cacheDirectory.delete(recursive: true);
  });

  test('cache store rejects an oversized serialized document cache', () async {
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'rag-cache-test-',
    );
    final store = RagCacheStore(
      directoryFactory: () async => cacheDirectory,
      policy: const RagCachePolicy(maxEntryBytes: 32),
    );

    expect(
      () => store.write(
        documentId: 'doc-oversized',
        chunks: [
          const RagChunk(
            id: 'doc-oversized_c0',
            documentId: 'doc-oversized',
            documentName: 'large.txt',
            text: 'This cache must be rejected.',
            charStartIndex: 0,
            charEndIndex: 28,
          ),
        ],
      ),
      throwsA(isA<RagCacheLimitExceededException>()),
    );

    await cacheDirectory.delete(recursive: true);
  });

  test('service supports injected vector and hybrid retrieval', () async {
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'rag-search-test-',
    );
    final settings = FakeRagSettings(
      apiKey: 'test-key',
      mode: RagSearchMode.vector,
    );
    final module = RagModule(
      databaseFactory: () => RagDatabase.forTesting(NativeDatabase.memory()),
      cacheStoreFactory: () =>
          RagCacheStore(directoryFactory: () async => cacheDirectory),
      embeddingClientFactory: ({required apiKey, logger}) => FakeRagEmbedding(),
    );

    await module.register(
      ModuleContext.fromMap({
        RagSettingsPort: settings,
        RagLoggerPort: RecordingRagLogger(),
      }),
    );
    await module.initialize();
    await module.activate();
    final nginx = await module.service.addDocument(
      name: 'nginx.txt',
      bytes: 'systemctl restart nginx'.codeUnits,
      mimeType: 'text/plain',
    );
    await module.service.addDocument(
      name: 'pods.txt',
      bytes: 'kubectl get pods'.codeUnits,
      mimeType: 'text/plain',
    );

    final vectorResults = await module.service.retrieve(
      'nginx',
      searchMode: 'vector',
    );
    expect(vectorResults.first.documentId, nginx.id);

    final hybridResults = await module.service.retrieve(
      'pods',
      searchMode: 'hybrid',
    );
    expect(hybridResults.first.documentName, 'pods.txt');

    await module.dispose();
    settings.dispose();
    await cacheDirectory.delete(recursive: true);
  });
}
