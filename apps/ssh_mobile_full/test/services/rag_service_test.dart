import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storage = TestStorageAdapter();
    await storage.init();
  });

  tearDown(() async {
    await storage.shutdown();
    storage.dispose();
  });

  group('TestRagService Core Tests', () {
    test('Initialization works with blank database', () async {
      final service = await createTestRagService(storage);
      addTearDown(service.dispose);
      await service.init();

      expect(service.isInitialized, true);
      expect(service.documents.isEmpty, true);
    });

    test(
      'Add, search, and delete document works through the Feature Module',
      () async {
        final service = await createTestRagService(storage);
        addTearDown(service.dispose);
        await service.init();

        // 1. 添加文档
        const docName = 'k8s_ops.txt';
        const text =
            'Kubernetes standard deployment instructions. '
            'Use kubectl get pods to view running pods. '
            'Use kubectl apply -f deployment.yaml to apply configuration.';
        final bytes = text.codeUnits;

        final metadata = await service.addDocument(
          name: docName,
          bytes: bytes,
          mimeType: 'text/plain',
        );

        expect(metadata.name, docName);
        expect(metadata.chunkCount > 0, true);
        expect(service.documents.length, 1);

        // 2. 检索
        final chunks = await service.retrieve('kubectl get pods');
        expect(chunks.isNotEmpty, true);
        expect(chunks.first.documentName, docName);
        expect(chunks.first.text.contains('kubectl get pods'), true);

        // 3. 删除文档并确认当前 Module 的索引与缓存均已清空
        await service.deleteDocument(metadata.id);
        expect(service.documents.isEmpty, true);

        final chunksAfterDelete = await service.retrieve('kubectl');
        expect(chunksAfterDelete.isEmpty, true);
      },
    );
  });
}
