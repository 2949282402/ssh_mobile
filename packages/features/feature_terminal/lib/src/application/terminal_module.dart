// Terminal Module 生命周期实现。
//
// Module 是 terminal.db 和 Repository 的唯一 Owner。Route 进入时由 App
// 创建并 activate，离开时先 deactivate，再关闭数据库，避免页面仍在访问
// Drift 句柄时被提前释放。

import 'package:app_core/app_core.dart';
import 'package:ssh_core/ssh_core.dart';

import '../data/database/terminal_database.dart';
import '../data/repository/drift_terminal_history_repository.dart';
import '../domain/terminal_ports.dart';

/// Terminal database constructor used by the production Module and tests.
typedef TerminalDatabaseFactory = TerminalDatabase Function();

/// Terminal Feature 的数据库和 Repository Module。
final class TerminalModule implements AppModule {
  /// 创建尚未注册的 Module。
  TerminalModule({TerminalDatabaseFactory? databaseFactory})
    : _databaseFactory = databaseFactory ?? TerminalDatabase.new;

  final TerminalDatabaseFactory _databaseFactory;

  @override
  String get id => 'feature_terminal';

  ModuleState _state = ModuleState.registered;

  /// 当前生命周期状态。
  @override
  ModuleState get state => _state;

  TerminalDatabase? _database;
  DriftTerminalHistoryRepository? _repository;
  SshSessionManager? _sshManager;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;

  /// 当前 Module 持有的数据库；注册并初始化后可用。
  TerminalDatabase get database =>
      _database ?? (throw StateError('TerminalModule is not initialized.'));

  /// 当前 Module 持有的历史 Repository。
  TerminalHistoryRepository get historyRepository =>
      _repository ?? (throw StateError('TerminalModule is not initialized.'));

  /// 已注册的 SSH 公共能力；Module 只保存引用，不拥有其生命周期。
  SshSessionManager get sshSessionManager =>
      _sshManager ?? (throw StateError('TerminalModule is not registered.'));

  /// 注册 App Scope 依赖；SSH 只保存公共接口引用。
  @override
  Future<void> register(ModuleContext context) async {
    if (_state == ModuleState.disposed) {
      throw StateError('TerminalModule has been disposed.');
    }
    _sshManager = context.require<SshSessionManager>();
  }

  /// 创建 terminal.db 和 Repository；重复调用共享同一个 Future。
  @override
  Future<void> initialize() {
    if (_state == ModuleState.disposed) {
      return Future<void>.error(
        StateError('TerminalModule has been disposed.'),
      );
    }
    final existing = _initializeFuture;
    if (existing != null) return existing;
    final future = _doInitialize();
    _initializeFuture = future;
    return future;
  }

  Future<void> _doInitialize() async {
    // ModuleState 不暴露 initializing 中间态；_initializeFuture 负责并发合并。
    final database = _databaseFactory();
    try {
      await database.customSelect('SELECT 1').getSingle();
      _database = database;
      _repository = DriftTerminalHistoryRepository(database);
      _state = ModuleState.initialized;
    } catch (_) {
      await database.dispose();
      _initializeFuture = null;
      _state = ModuleState.registered;
      rethrow;
    }
  }

  /// 当前 Terminal Route 激活 Module。
  @override
  Future<void> activate() async {
    if (_state == ModuleState.initialized || _state == ModuleState.active) {
      _state = ModuleState.active;
      return;
    }
    await initialize();
    _state = ModuleState.active;
  }

  /// 停止 Route 级订阅；数据库仍保留到 dispose，便于短暂切换页面。
  @override
  Future<void> deactivate() async {
    if (_state == ModuleState.active) _state = ModuleState.inactive;
  }

  /// 关闭数据库；重复调用幂等。
  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    await deactivate();
    final database = _database;
    _database = null;
    _repository = null;
    _sshManager = null;
    if (database != null) await database.dispose();
    _state = ModuleState.disposed;
  }
}
