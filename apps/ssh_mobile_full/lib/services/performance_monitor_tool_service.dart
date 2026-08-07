// 旧监控工具服务路径的兼容桥；工具序列化和操作路由归属 Feature Package。

import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'connection_target_binding.dart';
import 'performance_monitor_service.dart';

/// 旧 AI 工具依赖的监控能力契约。
abstract interface class PerformanceMonitorToolAdapter {
  Map<String, dynamic> getState();

  Map<String, dynamic> setSelectedServers(List<String> connectionIds);

  Map<String, dynamic> clearSelection();

  Future<Map<String, dynamic>> start();

  Map<String, dynamic> stop();

  Map<String, dynamic> stopForConnection(String connectionId);

  Map<String, dynamic> setInterval(Duration interval);

  Map<String, dynamic> setHistoryWindow(Duration window);

  Map<String, dynamic> getHealth({List<String>? connectionIds});

  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  });

  Map<String, dynamic> getAlerts({int limit = 50});

  Future<Map<String, dynamic>> getPorts(String connectionId);

  Future<Map<String, dynamic>> getApplications(String connectionId);
}

/// 旧 AI 工具依赖的审批目标扩展契约。
abstract interface class BoundPerformanceMonitorToolAdapter {
  Future<Map<String, dynamic>> startWithTargets(
    Map<String, ConnectionTargetBinding> targets,
  );
}

/// 旧监控工具服务外观；不拥有 AppRuntime 的监控服务。
class PerformanceMonitorToolService
    implements
        PerformanceMonitorToolAdapter,
        BoundPerformanceMonitorToolAdapter {
  /// 创建工具外观。
  PerformanceMonitorToolService(PerformanceMonitorService service)
    : service = service,
      _delegate = monitoring.MonitoringToolService(service.delegate);

  /// 兼容旧调用方读取的监控服务。
  final PerformanceMonitorService service;
  final monitoring.MonitoringToolService _delegate;

  @override
  Map<String, dynamic> getState() => _delegate.getState();

  @override
  Map<String, dynamic> setSelectedServers(List<String> connectionIds) =>
      _delegate.setSelectedServers(connectionIds);

  @override
  Map<String, dynamic> clearSelection() => _delegate.clearSelection();

  @override
  Future<Map<String, dynamic>> start() => _delegate.start();

  @override
  Future<Map<String, dynamic>> startWithTargets(
    Map<String, ConnectionTargetBinding> targets,
  ) {
    return _delegate.startWithTargets({
      for (final entry in targets.entries)
        entry.key: monitoringTargetFromLegacy(entry.value),
    });
  }

  @override
  Map<String, dynamic> stop() => _delegate.stop();

  @override
  Map<String, dynamic> stopForConnection(String connectionId) =>
      _delegate.stopForConnection(connectionId);

  @override
  Map<String, dynamic> setInterval(Duration interval) =>
      _delegate.setInterval(interval);

  @override
  Map<String, dynamic> setHistoryWindow(Duration window) =>
      _delegate.setHistoryWindow(window);

  @override
  Map<String, dynamic> getHealth({List<String>? connectionIds}) =>
      _delegate.getHealth(connectionIds: connectionIds);

  @override
  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  }) => _delegate.getSamples(
    connectionId,
    visibleOnly: visibleOnly,
    limit: limit,
  );

  @override
  Map<String, dynamic> getAlerts({int limit = 50}) =>
      _delegate.getAlerts(limit: limit);

  @override
  Future<Map<String, dynamic>> getPorts(String connectionId) =>
      _delegate.getPorts(connectionId);

  @override
  Future<Map<String, dynamic>> getApplications(String connectionId) =>
      _delegate.getApplications(connectionId);
}

/// 把旧目标绑定转换为 Core/Monitoring 使用的不可变快照。
ssh_core.SshTargetBinding monitoringTargetFromLegacy(
  ConnectionTargetBinding binding,
) {
  return ssh_core.SshTargetBinding.fromConfig(binding.config);
}
