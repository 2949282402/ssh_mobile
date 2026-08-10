import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_rag/feature_rag.dart';

final class _Settings extends ChangeNotifier implements RagSettingsPort {
  String apiKey = '';

  @override
  bool isEnglish = false;

  @override
  RagSearchMode get searchMode => RagSearchMode.bm25;

  @override
  Future<String?> getAliyunApiKey() async => apiKey.isEmpty ? null : apiKey;

  @override
  Future<void> saveAliyunApiKey(String key) async {
    apiKey = key;
    notifyListeners();
  }
}

final class _Logger implements RagLoggerPort {
  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RagModule module;
  late _Settings settings;
  late Directory cacheDirectory;

  setUp(() async {
    settings = _Settings();
    cacheDirectory = await Directory.systemTemp.createTemp('rag-vm-test-');
    module = RagModule(
      databaseFactory: () => RagDatabase.forTesting(NativeDatabase.memory()),
      cacheStoreFactory: () =>
          RagCacheStore(directoryFactory: () async => cacheDirectory),
    );
    await module.register(
      ModuleContext.fromMap({
        RagSettingsPort: settings,
        RagLoggerPort: _Logger(),
      }),
    );
    await module.initialize();
  });

  tearDown(() async {
    await module.dispose();
    settings.dispose();
    await cacheDirectory.delete(recursive: true);
  });

  group('RagKnowledgeViewModel Tests', () {
    test('Initialization status checks', () {
      final viewModel = RagKnowledgeViewModel(
        ragService: module.service,
        settings: settings,
      );

      expect(viewModel.documents, isEmpty);
      expect(viewModel.isLoading, isFalse);
      expect(viewModel.isProcessing, isFalse);
    });

    test('Aliyun API key save and retrieval updates settings', () async {
      final viewModel = RagKnowledgeViewModel(
        ragService: module.service,
        settings: settings,
      );

      var key = await viewModel.getAliyunApiKey();
      expect(key, isNull);

      await viewModel.saveAliyunApiKey('sk-123456');
      key = await viewModel.getAliyunApiKey();
      expect(key, equals('sk-123456'));
    });
  });
}
