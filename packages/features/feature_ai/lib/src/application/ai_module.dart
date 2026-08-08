// AI Feature 的 App Scope Module。
//
// Module 只在注册阶段保存 Port，不打开数据库；首次进入 AI 路由或首次发起
// 请求时由 initialize() 创建 ai.db 和 Repository。这样未使用 AI 时不会创建
// 文件、Provider、工具注册表或网络客户端。

import 'package:app_core/app_core.dart';

import '../data/database/ai_database.dart';
import '../data/repositories/ai_repository.dart';
import '../domain/ai_ports.dart';

typedef AiModuleDatabaseFactory = AiDatabase Function();

final class AiModule implements AppModule {
  AiModule({AiModuleDatabaseFactory? databaseFactory})
    : _databaseFactory = databaseFactory ?? AiDatabase.new;

  final AiModuleDatabaseFactory _databaseFactory;
  ModuleState _state = ModuleState.registered;
  AiStoragePort? _storage;
  AiSettingsPort? _settings;
  AiTextProtectionPort? _protection;
  AiLoggerPort? _logger;
  AiDatabase? _database;
  DriftAiRepository? _repository;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;

  @override
  String get id => 'feature_ai';

  @override
  ModuleState get state => _state;

  AiStoragePort get storage =>
      _storage ?? (throw StateError('AiModule is not registered.'));

  AiSettingsPort get settings =>
      _settings ?? (throw StateError('AiModule is not registered.'));

  AiRepository get repository =>
      _repository ?? (throw StateError('AiModule is not initialized.'));

  AiDatabase get database =>
      _database ?? (throw StateError('AiModule is not initialized.'));

  @override
  Future<void> register(ModuleContext context) async {
    if (_state == ModuleState.disposed) {
      throw StateError('AiModule has been disposed.');
    }
    _storage = context.require<AiStoragePort>();
    _settings = context.require<AiSettingsPort>();
    _protection = context.require<AiTextProtectionPort>();
    _logger = context.require<AiLoggerPort>();
    AiLoggerContext.install(_logger!);
  }

  @override
  Future<void> initialize() => _initializeFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    final protection = _protection;
    final logger = _logger;
    if (_storage == null ||
        _settings == null ||
        protection == null ||
        logger == null) {
      _initializeFuture = null;
      throw StateError('AiModule must be registered before initialize.');
    }

    AiDatabase? database;
    try {
      database = _databaseFactory();
      await database.customSelect('SELECT 1').getSingle();
      _database = database;
      _repository = DriftAiRepository(database, protection);
      _state = ModuleState.initialized;
      logger.info('AI module initialized', details: 'ai.db is ready');
    } catch (_) {
      await database?.dispose();
      _database = null;
      _repository = null;
      _initializeFuture = null;
      _state = ModuleState.registered;
      rethrow;
    }
  }

  @override
  Future<void> activate() async {
    await initialize();
    _state = ModuleState.active;
  }

  @override
  Future<void> deactivate() async {
    if (_state == ModuleState.active) _state = ModuleState.inactive;
  }

  /// 先释放 Repository，再关闭 ai.db；重复调用安全。
  @override
  Future<void> dispose() => _disposeFuture ??= _disposeResources();

  Future<void> _disposeResources() async {
    if (_state == ModuleState.disposed) return;
    await deactivate();
    _repository = null;
    final database = _database;
    _database = null;
    if (database != null) await database.dispose();
    _storage = null;
    _settings = null;
    _protection = null;
    final logger = _logger;
    _logger = null;
    if (logger != null) AiLoggerContext.reset(logger);
    _state = ModuleState.disposed;
  }
}
