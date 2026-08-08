// RAG Module 生命周期 Owner。
//
// Module 独占 rag.db、元数据 Repository、文件缓存和 Service；App Shell 只
// 注入设置与日志 Port，Route 再从 Module 创建自己的 ViewModel。

import 'package:app_core/app_core.dart';

import '../data/cache/rag_cache_store.dart';
import '../data/database/rag_database.dart';
import '../data/repositories/rag_repository.dart';
import '../domain/rag_ports.dart';
import 'rag_service.dart';

/// 供测试替换 rag.db 创建过程。
typedef RagDatabaseFactory = RagDatabase Function();

/// 供测试替换文件缓存目录和策略。
typedef RagCacheStoreFactory = RagCacheStore Function();

/// RAG Feature 的 App Scope Module。
final class RagModule implements AppModule {
  RagModule({
    RagDatabaseFactory? databaseFactory,
    RagCacheStoreFactory? cacheStoreFactory,
    RagEmbeddingFactory? embeddingClientFactory,
  }) : _databaseFactory = databaseFactory ?? RagDatabase.new,
       _cacheStoreFactory = cacheStoreFactory ?? RagCacheStore.new,
       // 保持外部 DI 参数使用稳定的公开名称，内部工厂字段不暴露给调用方。
       // ignore: prefer_initializing_formals
       _embeddingClientFactory = embeddingClientFactory;

  final RagDatabaseFactory _databaseFactory;
  final RagCacheStoreFactory _cacheStoreFactory;
  final RagEmbeddingFactory? _embeddingClientFactory;
  ModuleState _state = ModuleState.registered;
  RagSettingsPort? _settings;
  RagLoggerPort? _logger;
  RagDatabase? _database;
  DriftRagRepository? _repository;
  RagService? _service;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;

  @override
  String get id => 'feature_rag';

  @override
  ModuleState get state => _state;

  RagSettingsPort get settings =>
      _settings ?? (throw StateError('RagModule is not registered.'));

  RagDatabase get database =>
      _database ?? (throw StateError('RagModule is not initialized.'));

  RagRepository get repository =>
      _repository ?? (throw StateError('RagModule is not initialized.'));

  RagService get service =>
      _service ?? (throw StateError('RagModule is not initialized.'));

  @override
  Future<void> register(ModuleContext context) async {
    if (_state == ModuleState.disposed) {
      throw StateError('RagModule has been disposed.');
    }
    _settings = context.require<RagSettingsPort>();
    _logger = context.require<RagLoggerPort>();
  }

  @override
  Future<void> initialize() {
    if (_state == ModuleState.disposed) {
      return Future<void>.error(StateError('RagModule has been disposed.'));
    }
    return _initializeFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    final settings = _settings;
    final logger = _logger;
    if (settings == null || logger == null) {
      _initializeFuture = null;
      throw StateError('RagModule must be registered before initialize.');
    }

    RagDatabase? database;
    try {
      database = _databaseFactory();
      await database.customSelect('SELECT 1').getSingle();
      final repository = DriftRagRepository(database);
      final service = RagService(
        repository: repository,
        settings: settings,
        logger: logger,
        cacheStore: _cacheStoreFactory(),
        embeddingClientFactory: _embeddingClientFactory,
      );
      _database = database;
      _repository = repository;
      _service = service;
      _state = ModuleState.initialized;
    } catch (_) {
      await database?.dispose();
      _database = null;
      _repository = null;
      _service = null;
      _initializeFuture = null;
      _state = ModuleState.registered;
      rethrow;
    }
  }

  /// 激活只标记 Module 可用；RAG 文档索引仍按页面或 AI 首次使用懒加载。
  @override
  Future<void> activate() async {
    if (_state == ModuleState.active) return;
    await initialize();
    _state = ModuleState.active;
  }

  @override
  Future<void> deactivate() async {
    if (_state == ModuleState.active) _state = ModuleState.inactive;
  }

  /// 先停止 Service，再关闭 Module 自有数据库；重复调用安全。
  @override
  Future<void> dispose() => _disposeFuture ??= _disposeResources();

  Future<void> _disposeResources() async {
    if (_state == ModuleState.disposed) return;
    await deactivate();
    final service = _service;
    final database = _database;
    _service = null;
    _repository = null;
    _database = null;
    service?.dispose();
    if (database != null) await database.dispose();
    _settings = null;
    _logger = null;
    _state = ModuleState.disposed;
  }
}
