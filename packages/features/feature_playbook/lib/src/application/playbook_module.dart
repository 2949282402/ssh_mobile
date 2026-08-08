// Playbook Module 的生命周期 Owner。
//
// Module 独占数据库、Repository 和执行 Service；App Shell 只通过 Port 注入
// SSH、日志和数据保护能力。

import 'package:app_core/app_core.dart';

import '../data/database/playbook_database.dart' as db;
import '../data/repositories/playbook_repository.dart';
import '../domain/playbook_ports.dart';
import 'playbook_service.dart';

/// Playbook Feature 的数据库工厂。
typedef PlaybookModuleDatabaseFactory = db.PlaybookDatabase Function();

/// Playbook 的 Module Scope Owner。
final class PlaybookModule implements AppModule {
  PlaybookModule({PlaybookModuleDatabaseFactory? databaseFactory})
    : _databaseFactory = databaseFactory ?? db.PlaybookDatabase.new;

  final PlaybookModuleDatabaseFactory _databaseFactory;

  ModuleState _state = ModuleState.registered;
  db.PlaybookDatabase? _database;
  PlaybookRepository? _repository;
  PlaybookService? _service;
  PlaybookSshPort? _sshPort;
  PlaybookLoggerPort? _logger;
  PlaybookDataProtectionPort? _dataProtection;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;

  @override
  String get id => 'feature_playbook';

  @override
  ModuleState get state => _state;

  /// Module 自己创建的执行 Service。
  PlaybookService get service =>
      _service ?? (throw StateError('PlaybookModule is not initialized.'));

  /// Module 自己创建的 Repository，用于 App Shell 兼容适配。
  PlaybookRepository get repository =>
      _repository ?? (throw StateError('PlaybookModule is not initialized.'));

  /// Module 自己创建的数据库。
  db.PlaybookDatabase get database =>
      _database ?? (throw StateError('PlaybookModule is not initialized.'));

  @override
  Future<void> register(ModuleContext context) async {
    if (_state == ModuleState.disposed) {
      throw StateError('PlaybookModule has been disposed.');
    }
    _sshPort = context.require<PlaybookSshPort>();
    _logger = context.require<PlaybookLoggerPort>();
    _dataProtection = context.require<PlaybookDataProtectionPort>();
  }

  @override
  Future<void> initialize() => _initializeFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    final sshPort = _sshPort;
    final logger = _logger;
    final dataProtection = _dataProtection;
    if (sshPort == null || logger == null || dataProtection == null) {
      _initializeFuture = null;
      throw StateError('PlaybookModule must be registered first.');
    }

    final database = _databaseFactory();
    try {
      await database.customSelect('SELECT 1').get();
      final repository = DriftPlaybookRepository(
        database: database,
        dataProtection: dataProtection,
      );
      final service = PlaybookService(
        repository: repository,
        sshPort: sshPort,
        logger: logger,
      );
      _database = database;
      _repository = repository;
      _service = service;
      await service.initialize();
      _state = ModuleState.initialized;
    } catch (_) {
      await database.dispose();
      rethrow;
    }
  }

  /// 激活只代表允许执行；不会自动连接服务器或启动后台轮询。
  @override
  Future<void> activate() async {
    if (_state == ModuleState.active) return;
    await initialize();
    _state = ModuleState.active;
  }

  @override
  Future<void> deactivate() async {
    if (_state == ModuleState.active) {
      _state = ModuleState.inactive;
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _disposeResources();

  Future<void> _disposeResources() async {
    await deactivate();
    _service?.dispose();
    _service = null;
    _repository = null;
    final database = _database;
    _database = null;
    _sshPort = null;
    _logger = null;
    _dataProtection = null;
    if (database != null) await database.dispose();
    _state = ModuleState.disposed;
  }
}
