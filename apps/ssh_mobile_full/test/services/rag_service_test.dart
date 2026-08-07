import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock path_provider MethodChannel
  const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );

  late StorageService storage;

  Future<void> cleanRagFiles() async {
    final dir = Directory('.');
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name == 'rag_database.json' ||
              name == 'rag_metadata.json' ||
              name.startsWith('rag_doc_')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    }
  }

  setUp(() async {
    await cleanRagFiles();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return '.'; // 返回当前测试运行根目录作为 support 目录
        });

    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    storage.dispose();
    await cleanRagFiles();
  });

  group('RagService Core Tests', () {
    test('Initialization works with blank database', () async {
      final service = RagService(storageService: storage);
      await service.init();

      expect(service.isInitialized, true);
      expect(service.documents.isEmpty, true);
    });

    test(
      'Add, search, and delete document works perfectly with persistence',
      () async {
        final service = RagService(storageService: storage);
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

        // 3. 测试持久化：创建一个新服务实例并加载
        final service2 = RagService(storageService: storage);
        await service2.init();

        expect(service2.documents.length, 1);
        expect(service2.documents.first.name, docName);

        final chunks2 = await service2.retrieve('kubectl apply');
        expect(chunks2.isNotEmpty, true);
        expect(chunks2.first.text.contains('kubectl apply'), true);

        // 4. 删除文档
        await service2.deleteDocument(metadata.id);
        expect(service2.documents.isEmpty, true);

        final chunks3 = await service2.retrieve('kubectl');
        expect(chunks3.isEmpty, true);

        // 5. 验证数据库文件重新保存后为空
        final service3 = RagService(storageService: storage);
        await service3.init();
        expect(service3.documents.isEmpty, true);
      },
    );
  });
}
