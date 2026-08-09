// 旧 PerformanceMonitorService API 的兼容桥。
//
// 监控采样、Timer、健康评分和解析逻辑已经归属 feature_monitoring；本文件只
// 把旧 App 依赖适配到 Feature Port，并保留现有调用方的类型和方法面。

import 'dart:async';

import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/ssh_host_key_policy.dart' as legacy_ssh;
import '../features/connection/models/connection.dart';
import 'app_settings.dart';
import 'app_log_service.dart';
import 'background_service.dart';
import 'connection_target_binding.dart';
import 'server_status_probe.dart';
import 'ssh_service.dart';

part 'performance_monitor_models.dart';

/// 兼容旧调用点的监控服务外观；实际状态由 Feature 服务唯一持有。
class PerformanceMonitorService extends ChangeNotifier {
  /// 监控服务允许保留的最大内存窗口。
  static const Duration maxRetention =
      monitoring.MonitoringService.maxRetention;

  /// 默认采样间隔。
  static const Duration defaultInterval =
      monitoring.MonitoringService.defaultInterval;

  /// 默认历史窗口。
  static const Duration defaultHistoryWindow =
      monitoring.MonitoringService.defaultHistoryWindow;

  /// UI 可选的采样间隔。
  static const List<Duration> intervalOptions =
      monitoring.MonitoringService.intervalOptions;

  /// UI 可选的历史窗口。
  static const List<Duration> historyWindowOptions =
      monitoring.MonitoringService.historyWindowOptions;

  /// 创建旧 App 依赖的兼容服务。
  factory PerformanceMonitorService(
    SshService sshService,
    ConnectionRepository connectionRepository, {
    AppSettings? appSettings,
  }) {
    return PerformanceMonitorService._(
      monitoring.MonitoringService(
        sshPort: _LegacyMonitoringSshPort(sshService),
        connectionCatalog: _LegacyMonitoringConnectionCatalog(
          connectionRepository,
        ),
        logger: const _LegacyMonitoringLogger(),
        background: _LegacyMonitoringBackground(appSettings),
      ),
      ownsDelegate: true,
    );
  }

  /// 从 AppRuntime 已创建的 Feature 服务构造非 Owner 兼容外观。
  PerformanceMonitorService.fromDelegate(monitoring.MonitoringService delegate)
    : this._(delegate, ownsDelegate: false);

  PerformanceMonitorService._(this._delegate, {required this._ownsDelegate}) {
    _delegate.addListener(notifyListeners);
  }

  final monitoring.MonitoringService _delegate;
  final bool _ownsDelegate;

  /// 暴露给 App Composition Root 的真实 Feature Owner。
  monitoring.MonitoringService get delegate => _delegate;

  /// 当前是否正在轮询。
  bool get isRunning => _delegate.isRunning;

  /// 当前是否有采样任务。
  bool get isSampling => _delegate.isSampling;

  /// 返回指定连接是否正在采样。
  bool isSamplingConnection(String connectionId) =>
      _delegate.isSamplingConnection(connectionId);

  /// 当前采样间隔。
  Duration get interval => _delegate.interval;

  /// 考虑失败退避后的采样间隔。
  Duration get effectiveInterval => _delegate.effectiveInterval;

  /// 当前历史窗口。
  Duration get historyWindow => _delegate.historyWindow;

  /// 轮询启动时间。
  DateTime? get startedAt => _delegate.startedAt;

  /// 当前选择的服务器。
  Set<String> get selectedConnectionIds => _delegate.selectedConnectionIds;

  /// 当前正在监控的服务器。
  Set<String> get monitoringConnectionIds => _delegate.monitoringConnectionIds;

  /// 每个连接的最新错误。
  Map<String, String> get errorsByConnection => _delegate.errorsByConnection;

  /// 告警列表。
  List<MonitorAlert> get alerts => _delegate.alerts;

  /// 所有连接健康状态。
  Map<String, ServerHealthSnapshot> get healthByConnection =>
      _delegate.healthByConnection;

  /// 读取磁盘使用数据。
  List<DiskUsageSnapshot> diskUsageFor(String connectionId) =>
      _delegate.diskUsageFor(connectionId);

  /// 读取完整样本窗口。
  List<PerformanceSample> samplesFor(String connectionId) =>
      _delegate.samplesFor(connectionId);

  /// 读取连接健康状态。
  ServerHealthSnapshot healthFor(String connectionId) =>
      _delegate.healthFor(connectionId);

  /// 读取历史窗口内的样本。
  List<PerformanceSample> visibleSamplesFor(String connectionId) =>
      _delegate.visibleSamplesFor(connectionId);

  /// 切换服务器选择。
  void toggleSelection(String connectionId) =>
      _delegate.toggleSelection(connectionId);

  /// 清空服务器选择。
  void clearSelection() => _delegate.clearSelection();

  /// 启动轮询，并把旧 Host Key 回调转换为 Core 契约。
  Future<void> startMonitoring({
    legacy_ssh.SshHostKeyConfirmation? onUnknownHostKey,
    Map<String, ConnectionTargetBinding>? targetBindings,
  }) {
    return _delegate.startMonitoring(
      onUnknownHostKey: _toCoreConfirmation(onUnknownHostKey),
      targetBindings: targetBindings == null
          ? null
          : {
              for (final entry in targetBindings.entries)
                entry.key: ssh_core.SshTargetBinding.fromConfig(
                  entry.value.config,
                ),
            },
    );
  }

  /// 停止轮询。
  void stopMonitoring() => _delegate.stopMonitoring();

  /// 移除指定连接及其采样状态。
  void stopForConnection(String connectionId) =>
      _delegate.stopForConnection(connectionId);

  /// 修改轮询间隔。
  void setInterval(Duration interval) => _delegate.setInterval(interval);

  /// 修改历史窗口。
  void setHistoryWindow(Duration window) => _delegate.setHistoryWindow(window);

  /// 显式采样一次。
  Future<void> sampleNow({
    legacy_ssh.SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _delegate.sampleNow(
      onUnknownHostKey: _toCoreConfirmation(onUnknownHostKey),
    );
  }

  /// 查询监听端口。
  Future<List<PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    legacy_ssh.SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _delegate.fetchPorts(
      connectionId,
      onUnknownHostKey: _toCoreConfirmation(onUnknownHostKey),
    );
  }

  /// 查询高内存进程。
  Future<List<ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    legacy_ssh.SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _delegate.fetchApplications(
      connectionId,
      onUnknownHostKey: _toCoreConfirmation(onUnknownHostKey),
    );
  }

  /// 查询服务状态。
  Future<List<ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    legacy_ssh.SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _delegate.fetchServices(
      connectionId,
      onUnknownHostKey: _toCoreConfirmation(onUnknownHostKey),
    );
  }

  @override
  void dispose() {
    _delegate.removeListener(notifyListeners);
    if (_ownsDelegate) _delegate.dispose();
    super.dispose();
  }
}

ssh_core.SshHostKeyConfirmation? _toCoreConfirmation(
  legacy_ssh.SshHostKeyConfirmation? callback,
) {
  if (callback == null) return null;
  return (request) => callback(
    legacy_ssh.SshHostKeyPromptRequest(
      connectionId: request.connectionId,
      connectionName: request.connectionName,
      host: request.host,
      port: request.port,
      username: request.username,
      algorithm: request.algorithm,
      fingerprint: request.fingerprint,
    ),
  );
}

/// 旧 SshService 到 MonitoringSshPort 的兼容适配器。
final class _LegacyMonitoringSshPort implements monitoring.MonitoringSshPort {
  const _LegacyMonitoringSshPort(this._sshService);

  final SshService _sshService;

  @override
  Future<ssh_core.RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    monitoring.MonitoringRequestPriority priority =
        monitoring.MonitoringRequestPriority.low,
  }) async {
    _ensureLowPriority(priority);
    final result = await _sshService.runOneShotCommand(
      connectionId: connectionId,
      command: command,
      timeout: timeout,
      onUnknownHostKey: _toLegacyConfirmation(onUnknownHostKey),
    );
    return ssh_core.RemoteCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  @override
  Future<ssh_core.RemoteCommandResult> runOneShotCommandForBinding({
    required ssh_core.SshTargetBinding binding,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    monitoring.MonitoringRequestPriority priority =
        monitoring.MonitoringRequestPriority.low,
  }) async {
    _ensureLowPriority(priority);
    final legacyBinding = ConnectionTargetBinding.fromConfig(binding.config);
    final result = await _sshService.runOneShotCommandForBinding(
      binding: legacyBinding,
      command: command,
      timeout: timeout,
      onUnknownHostKey: _toLegacyConfirmation(onUnknownHostKey),
    );
    return ssh_core.RemoteCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  void _ensureLowPriority(monitoring.MonitoringRequestPriority priority) {
    if (priority != monitoring.MonitoringRequestPriority.low) {
      throw StateError('Monitoring SSH requests must use low priority.');
    }
  }
}

legacy_ssh.SshHostKeyConfirmation? _toLegacyConfirmation(
  ssh_core.SshHostKeyConfirmation? callback,
) {
  if (callback == null) return null;
  return (request) => callback(
    ssh_core.SshHostKeyPromptRequest(
      connectionId: request.connectionId,
      connectionName: request.connectionName,
      host: request.host,
      port: request.port,
      username: request.username,
      algorithm: request.algorithm,
      fingerprint: request.fingerprint,
    ),
  );
}

/// Connection Core 到 Monitoring 连接 Port 的兼容适配器。
final class _LegacyMonitoringConnectionCatalog
    implements monitoring.MonitoringConnectionCatalogPort {
  const _LegacyMonitoringConnectionCatalog(this._connectionRepository);

  final ConnectionRepository _connectionRepository;

  @override
  ServerPlatform? serverPlatformFor(String connectionId) =>
      _connectionRepository.getConnection(connectionId)?.serverPlatform;
}

/// 旧 AppLogService 到 Feature Logger Port 的兼容适配器。
final class _LegacyMonitoringLogger implements monitoring.MonitoringLoggerPort {
  const _LegacyMonitoringLogger();

  @override
  void warning(String message, {String? details}) {
    AppLogService.instance.warning(message, details: details);
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    AppLogService.instance.error(
      message,
      error: error,
      stackTrace: stackTrace,
      details: details,
    );
  }
}

/// 旧后台前台服务到 Feature Port 的兼容适配器。
final class _LegacyMonitoringBackground
    implements monitoring.MonitoringBackgroundPort {
  const _LegacyMonitoringBackground(this._appSettings);

  final AppSettings? _appSettings;

  @override
  Future<void> start({required String connectionName}) {
    return BackgroundServiceManager.start(
      connectionName: connectionName,
      showConnectionName: _appSettings?.showServerNamesInNotifications ?? false,
    );
  }
}
