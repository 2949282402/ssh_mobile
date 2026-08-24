// System Admin Module 的生命周期实现。
//
// Module 只拥有管理 Service；连接目录、SSH 基础设施、监控和 SFTP 能力由
// App Shell 注入。当前模块没有数据库，dispose 必须先停止命令再关闭管理会话。

import 'package:app_core/app_core.dart';

import '../domain/system_admin_ports.dart';
import 'system_admin_service.dart';

/// System Admin 管理服务的构造器，供生命周期测试注入假实现。
typedef SystemAdminServiceFactory =
    SystemAdminService Function(
      SystemAdminSshPort sshPort,
      SystemAdminLoggerPort logger,
    );

/// System Admin Feature 的 Module Scope Owner。
final class SystemAdminModule implements AppModule {
  /// 创建尚未注册的 Module。
  SystemAdminModule({SystemAdminServiceFactory? serviceFactory})
    : _serviceFactory =
          serviceFactory ??
          ((sshPort, logger) =>
              SystemAdminService(sshPort: sshPort, logger: logger));

  final SystemAdminServiceFactory _serviceFactory;
  ModuleState _state = ModuleState.registered;
  SystemAdminSshPort? _sshPort;
  SystemAdminLoggerPort? _logger;
  SystemAdminService? _service;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;
  int _lifecycleGeneration = 0;

  @override
  String get id => 'feature_system_admin';

  @override
  ModuleState get state => _state;

  /// 当前 Module 创建的管理服务。
  SystemAdminService get service =>
      _service ?? (throw StateError('SystemAdminModule is not initialized.'));

  /// 注册 App Shell Port。
  @override
  Future<void> register(ModuleContext context) async {
    if (_state == ModuleState.disposed) {
      throw StateError('SystemAdminModule has been disposed.');
    }
    _sshPort = context.require<SystemAdminSshPort>();
    _logger = context.require<SystemAdminLoggerPort>();
  }

  /// 创建管理服务；重复初始化共享同一个 Future。
  @override
  Future<void> initialize() {
    if (_state == ModuleState.disposed) {
      return Future<void>.error(
        StateError('SystemAdminModule has been disposed.'),
      );
    }
    return _initializeFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    final sshPort = _sshPort;
    final logger = _logger;
    if (sshPort == null || logger == null) {
      _initializeFuture = null;
      throw StateError('SystemAdminModule must be registered first.');
    }
    _service = _serviceFactory(sshPort, logger);
    _state = ModuleState.initialized;
  }

  /// 激活模块；不会自动连接或执行管理命令。
  @override
  Future<void> activate() async {
    if (_state == ModuleState.active) return;
    final generation = _lifecycleGeneration;
    await initialize();
    if (_state == ModuleState.disposed || generation != _lifecycleGeneration) {
      return;
    }
    _state = ModuleState.active;
  }

  /// 停止模块接受新的管理操作。
  @override
  Future<void> deactivate() async {
    if (_state == ModuleState.active) {
      service.cancelActiveCommands();
      _state = ModuleState.inactive;
    }
  }

  /// 关闭服务和 App Shell 传入的当前管理会话。
  @override
  Future<void> dispose() {
    return _disposeFuture ??= _disposeResources();
  }

  Future<void> _disposeResources() async {
    ++_lifecycleGeneration;
    final wasActive = _state == ModuleState.active;
    _state = ModuleState.disposed;
    final service = _service;
    if (service != null) {
      if (wasActive) service.cancelActiveCommands();
      await service.close();
      service.dispose();
    }
    _service = null;
    _sshPort = null;
    _logger = null;
  }
}
