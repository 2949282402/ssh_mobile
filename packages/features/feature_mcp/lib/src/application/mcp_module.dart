// MCP Feature 的 App Scope 生命周期 Owner。
//
// Module 独占 mcp.db、活动 Repository、审批队列和本地 HTTP Server；App Shell
// 只通过 Settings、Logger 和工具运行时 Port 注入外部能力。

import 'package:app_core/app_core.dart';

import '../data/database/mcp_database.dart';
import '../data/repositories/mcp_activity_repository.dart';
import '../domain/mcp_activity.dart';
import '../domain/mcp_ports.dart';
import 'mcp_server_controller.dart';

/// MCP Module 可替换的数据库工厂。
typedef McpModuleDatabaseFactory = McpDatabase Function();

/// MCP Feature 的 App Scope Owner。
final class McpModule implements AppModule {
  McpModule({McpModuleDatabaseFactory? databaseFactory})
    : _databaseFactory = databaseFactory ?? McpDatabase.new;

  final McpModuleDatabaseFactory _databaseFactory;
  ModuleState _state = ModuleState.registered;
  McpSettingsPort? _settings;
  McpLoggerPort? _logger;
  McpToolRuntimePort? _toolRuntime;
  McpDatabase? _database;
  DriftMcpActivityRepository? _repository;
  McpServerController? _service;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;

  @override
  String get id => 'feature_mcp';

  @override
  ModuleState get state => _state;

  /// MCP Module 的设置 Port。
  McpSettingsPort get settings =>
      _settings ?? (throw StateError('McpModule is not registered.'));

  /// Module 创建并持有的 MCP Server Controller。
  McpServerController get service =>
      _service ?? (throw StateError('McpModule is not initialized.'));

  /// Module 创建并持有的活动 Repository。
  McpActivityRepository get repository =>
      _repository ?? (throw StateError('McpModule is not initialized.'));

  /// Module 创建并持有的独立数据库。
  McpDatabase get database =>
      _database ?? (throw StateError('McpModule is not initialized.'));

  @override
  Future<void> register(ModuleContext context) async {
    if (_state == ModuleState.disposed) {
      throw StateError('McpModule has been disposed.');
    }
    _settings = context.require<McpSettingsPort>();
    _logger = context.require<McpLoggerPort>();
    _toolRuntime = context.require<McpToolRuntimePort>();
  }

  @override
  Future<void> initialize() {
    if (_state == ModuleState.disposed) {
      return Future<void>.error(StateError('McpModule has been disposed.'));
    }
    return _initializeFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    final settings = _settings;
    final logger = _logger;
    final toolRuntime = _toolRuntime;
    if (settings == null || logger == null || toolRuntime == null) {
      _initializeFuture = null;
      throw StateError('McpModule must be registered before initialize.');
    }

    McpDatabase? database;
    try {
      database = _databaseFactory();
      await database.customSelect('SELECT 1').getSingle();
      if (_state == ModuleState.disposed) {
        throw StateError('McpModule was disposed during initialization.');
      }
      final repository = DriftMcpActivityRepository(database);
      final service = McpServerController(
        settings: settings,
        toolServiceFactory: toolRuntime.createToolExecutor,
        activityRepository: repository,
        logger: logger,
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
      if (_state != ModuleState.disposed) _state = ModuleState.registered;
      rethrow;
    }
  }

  /// 激活只标记可用；是否启动 HTTP Server 由 App 生命周期显式决定。
  @override
  Future<void> activate() async {
    if (_state == ModuleState.active) return;
    await initialize();
    if (_state == ModuleState.disposed) return;
    _state = ModuleState.active;
  }

  @override
  Future<void> deactivate() async {
    if (_state == ModuleState.active) _state = ModuleState.inactive;
  }

  /// 先停止 Server 和审批队列，再关闭 mcp.db；重复调用安全。
  @override
  Future<void> dispose() => _disposeFuture ??= _disposeResources();

  Future<void> _disposeResources() async {
    if (_state == ModuleState.disposed) return;
    _state = ModuleState.disposed;
    final initialization = _initializeFuture;
    if (initialization != null) {
      try {
        await initialization;
      } catch (_) {
        // Initialization observes disposed and releases its local database.
      }
    }
    final service = _service;
    final database = _database;
    _service = null;
    _repository = null;
    _database = null;
    if (service != null) {
      await service.close();
      service.dispose();
    }
    if (database != null) await database.dispose();
    _settings = null;
    _logger = null;
    _toolRuntime = null;
  }
}
