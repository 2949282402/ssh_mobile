part of 'test_storage_adapter.dart';

/// 测试边界的 RAG Module Owner；Service、数据库和缓存仍按 Package 生命周期
/// 创建，App 测试不再构造旧 RAG facade。
Future<TestRagService> createTestRagService(
  TestStorageAdapter storage, {
  rag.RagSearchMode searchMode = rag.RagSearchMode.bm25,
}) async {
  final cacheDirectory = Directory.systemTemp.createTempSync(
    'ssh-mobile-rag-test-',
  );
  final settings = _TestRagSettings(storage.aiStorage, searchMode);
  final module = rag.RagModule(
    databaseFactory: () => rag.RagDatabase.forTesting(NativeDatabase.memory()),
    cacheStoreFactory: () =>
        rag.RagCacheStore(directoryFactory: () async => cacheDirectory),
  );
  await module.register(
    ModuleContext.fromMap({
      rag.RagSettingsPort: settings,
      rag.RagLoggerPort: const _TestRagLogger(),
    }),
  );
  await module.initialize();
  await module.activate();
  final service = TestRagService(module, cacheDirectory);
  storage._registerRagService(service);
  return service;
}

final class TestRagService extends ChangeNotifier implements rag.RagCapability {
  TestRagService(this._module, this._cacheDirectory) {
    _module.service.addListener(notifyListeners);
  }

  final rag.RagModule _module;
  final Directory _cacheDirectory;
  Future<void>? _closeFuture;

  rag.RagService get service => _module.service;

  List<rag.RagDocumentMetadata> get documents => service.documents;

  bool get isLoading => service.isLoading;

  bool get isInitialized => service.isInitialized;

  Future<void> init({bool force = false}) => service.init(force: force);

  Future<rag.RagDocumentMetadata> addDocument({
    required String name,
    required List<int> bytes,
    required String mimeType,
  }) => service.addDocument(name: name, bytes: bytes, mimeType: mimeType);

  Future<void> deleteDocument(String documentId) =>
      service.deleteDocument(documentId);

  @override
  Future<List<rag.RagChunk>> retrieve(
    String query, {
    int limit = 3,
    Set<String>? filterDocumentIds,
    String? searchMode,
    String? aliyunApiKey,
  }) => service.retrieve(
    query,
    limit: limit,
    filterDocumentIds: filterDocumentIds,
    searchMode: searchMode,
    aliyunApiKey: aliyunApiKey,
  );

  /// 等待 Module 关闭，用于 App 测试夹具的显式生命周期收尾。
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    _module.service.removeListener(notifyListeners);
    await _module.dispose();
    try {
      _cacheDirectory.deleteSync(recursive: true);
    } on FileSystemException {
      // Cache cleanup is best effort when a platform still holds a file handle.
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

final class _TestRagSettings extends ChangeNotifier
    implements rag.RagSettingsPort {
  _TestRagSettings(this._storage, this.searchMode);

  final AppAiStorageAdapter _storage;

  @override
  final rag.RagSearchMode searchMode;

  @override
  bool get isEnglish => false;

  @override
  Future<String?> getAliyunApiKey() => _storage.getAliyunApiKey();

  @override
  Future<void> saveAliyunApiKey(String key) => _storage.saveAliyunApiKey(key);
}

final class _TestRagLogger implements rag.RagLoggerPort {
  const _TestRagLogger();

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}
