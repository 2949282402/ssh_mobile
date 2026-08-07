// Monitoring Module 的资源生命周期边界。

import 'package:app_core/app_core.dart';

import '../domain/monitoring_ports.dart';
import 'monitoring_service.dart';

/// 监控模块的 App Scope Owner。
///
/// Module 激活本身不会开始轮询；轮询只能由用户或受控工具显式调用
/// [MonitoringService.startMonitoring]，避免 App 启动即永久占用 SSH。
final class MonitoringModule implements AppModule {
  /// 创建一个尚未注册依赖的监控 Module。
  MonitoringModule();

  MonitoringSshPort? _sshPort;
  MonitoringConnectionCatalogPort? _connectionCatalog;
  MonitoringLoggerPort? _logger;
  MonitoringBackgroundPort? _background;
  MonitoringService? _service;
  ModuleState _state = ModuleState.registered;

  @override
  String get id => 'monitoring';

  @override
  ModuleState get state => _state;

  /// 取已初始化的 App Scope 服务。
  MonitoringService get service {
    final value = _service;
    if (value == null) {
      throw StateError('MonitoringModule has not been initialized.');
    }
    return value;
  }

  @override
  Future<void> register(ModuleContext context) async {
    if (_state != ModuleState.registered) {
      throw StateError('MonitoringModule can only register once.');
    }
    _sshPort = context.require<MonitoringSshPort>();
    _connectionCatalog = context.require<MonitoringConnectionCatalogPort>();
    _logger = context.require<MonitoringLoggerPort>();
    _background = context.maybeGet<MonitoringBackgroundPort>();
  }

  @override
  Future<void> initialize() async {
    if (_state == ModuleState.initialized ||
        _state == ModuleState.inactive ||
        _state == ModuleState.active) {
      return;
    }
    if (_state != ModuleState.registered) {
      throw StateError('MonitoringModule cannot initialize from $_state.');
    }
    _service = MonitoringService(
      sshPort: _sshPort!,
      connectionCatalog: _connectionCatalog!,
      logger: _logger!,
      background: _background,
    );
    _state = ModuleState.initialized;
  }

  @override
  Future<void> activate() async {
    if (_state == ModuleState.active) return;
    if (_state != ModuleState.initialized && _state != ModuleState.inactive) {
      throw StateError('MonitoringModule cannot activate from $_state.');
    }
    // 激活只恢复模块可用状态，不启动用户未请求的 polling Timer。
    _state = ModuleState.active;
  }

  @override
  Future<void> deactivate() async {
    if (_state == ModuleState.inactive || _state == ModuleState.initialized) {
      return;
    }
    if (_state != ModuleState.active) {
      throw StateError('MonitoringModule cannot deactivate from $_state.');
    }
    service.stopMonitoring();
    _state = ModuleState.inactive;
  }

  @override
  Future<void> dispose() async {
    if (_state == ModuleState.disposed) return;
    service.stopMonitoring();
    service.dispose();
    _service = null;
    _state = ModuleState.disposed;
  }
}
