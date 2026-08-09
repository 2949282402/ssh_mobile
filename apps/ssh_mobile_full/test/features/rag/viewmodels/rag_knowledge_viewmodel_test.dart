import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/rag/viewmodels/rag_knowledge_viewmodel.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import '../../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;
  late RagService ragService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = TestStorageAdapter();
    await storageService.init();

    ragService = RagService(aiStorage: storageService.aiStorage);
  });

  tearDown(() {
    storageService.dispose();
  });

  group('RagKnowledgeViewModel Tests', () {
    test('Initialization status checks', () {
      final viewModel = RagKnowledgeViewModel(
        ragService: ragService,
        aiStorage: storageService.aiStorage,
      );

      expect(viewModel.documents, isEmpty);
      expect(viewModel.isLoading, isFalse);
      expect(viewModel.isProcessing, isFalse);
    });

    test('Aliyun API key save and retrieval updates settings', () async {
      final viewModel = RagKnowledgeViewModel(
        ragService: ragService,
        aiStorage: storageService.aiStorage,
      );

      var key = await viewModel.getAliyunApiKey();
      expect(key, isNull);

      await viewModel.saveAliyunApiKey('sk-123456');
      key = await viewModel.getAliyunApiKey();
      expect(key, equals('sk-123456'));
    });
  });
}
