import 'dart:async';
import 'dart:math';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../domain/monitoring_models.dart';
import '../domain/monitoring_ports.dart';
import '../domain/server_status_probe.dart';
import 'monitoring_alert_evaluator.dart';
import 'monitoring_sample_store.dart';

/// 服务器性能监控采样服务。
///
/// 可配置参数：
/// - 采样间隔：2s / 5s / 10s / 15s / 30s / 1m / 2m / 5m
/// - 历史窗口：30s / 1m / 2m / 3m / 5m / 10m
///
/// 特性：
/// - 指数退避重试（SSH 临时失败自动重试）
/// - 健康评分：CPU/内存/磁盘阈值打分，生成 alerts
/// - 告警去重：同类型告警 5 分钟内不重复发出
/// - 不可变视图：所有暴露的集合使用 List.unmodifiable 或 Set.unmodifiable
/// - 缓存优化：采样数据按 connectionId 分组，只通知关联监听器
/// 服务器实时监控服务。
///
/// 服务只在显式调用 [startMonitoring] 后创建 polling Timer；SSH、连接目录、
/// 日志和后台服务都通过 Port 注入，避免 Feature 反向依赖 App 实现。
class MonitoringService extends ChangeNotifier {
  static const Duration maxRetention = Duration(minutes: 10);
  static const Duration defaultInterval = Duration(seconds: 10);
  static const Duration defaultHistoryWindow = Duration(minutes: 5);
  static const List<Duration> intervalOptions = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  static const List<Duration> historyWindowOptions = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 3),
    Duration(minutes: 5),
    Duration(minutes: 10),
  ];

  final MonitoringSshPort _sshPort;
  final MonitoringConnectionCatalogPort _connectionCatalog;
  final MonitoringLoggerPort _logger;
  final MonitoringBackgroundPort? _background;
  Timer? _timer;
  bool _disposed = false;
  bool _running = false;
  DateTime? _startedAt;
  Duration _interval = defaultInterval;
  final Set<String> _selectedConnectionIds = {};
  final Set<String> _monitoringConnectionIds = {};
  Map<String, ssh_core.SshTargetBinding>? _monitoringTargetBindings;
  final Set<String> _samplingConnectionIds = {};
  final Map<String, int> _failureCountsByConnection = {};
  final MonitoringSampleStore _sampleStore;
  final MonitoringAlertEvaluator _alertEvaluator;
  Set<String>? _selectedConnectionIdsView;
  Set<String>? _monitoringConnectionIdsView;

  /// 创建一个尚未启动轮询的监控服务。
  factory MonitoringService({
    required MonitoringSshPort sshPort,
    required MonitoringConnectionCatalogPort connectionCatalog,
    required MonitoringLoggerPort logger,
    MonitoringBackgroundPort? background,
  }) => MonitoringService._(sshPort, connectionCatalog, logger, background);

  MonitoringService._(
    this._sshPort,
    this._connectionCatalog,
    this._logger,
    this._background,
  ) : _sampleStore = MonitoringSampleStore(
        historyWindow: defaultHistoryWindow,
        maxRetention: maxRetention,
      ),
      _alertEvaluator = MonitoringAlertEvaluator();

  bool get isRunning => _running;
  bool get isSampling => _samplingConnectionIds.isNotEmpty;
  bool isSamplingConnection(String connectionId) =>
      _samplingConnectionIds.contains(connectionId);
  Duration get interval => _interval;
  Duration get effectiveInterval => _effectiveInterval;
  Duration get historyWindow => _sampleStore.historyWindow;
  DateTime? get startedAt => _startedAt;
  Set<String> get selectedConnectionIds =>
      _selectedConnectionIdsView ??= Set.unmodifiable(_selectedConnectionIds);
  Set<String> get monitoringConnectionIds => _monitoringConnectionIdsView ??=
      Set.unmodifiable(_monitoringConnectionIds);
  Map<String, String> get errorsByConnection => _sampleStore.errors;
  List<MonitorAlert> get alerts => _alertEvaluator.alerts;
  Map<String, ServerHealthSnapshot> get healthByConnection =>
      _sampleStore.healthForConnections(<String>{
        ..._selectedConnectionIds,
        ..._monitoringConnectionIds,
      });
  List<DiskUsageSnapshot> diskUsageFor(String connectionId) =>
      _sampleStore.diskUsageFor(connectionId);
  List<PerformanceSample> samplesFor(String connectionId) =>
      _sampleStore.samplesFor(connectionId);
  ServerHealthSnapshot healthFor(String connectionId) =>
      _sampleStore.healthFor(connectionId);
  List<PerformanceSample> visibleSamplesFor(String connectionId) =>
      _sampleStore.visibleSamplesFor(connectionId);

  // Sampling widgets read these snapshots several times per build. Keep stable
  // immutable views and invalidate only the affected connection when data moves.
  void _invalidateSelectionCache() {
    _selectedConnectionIdsView = null;
    _sampleStore.invalidateConnectionSet();
  }

  void _invalidateMonitoringCache() {
    _monitoringConnectionIdsView = null;
    _sampleStore.invalidateConnectionSet();
  }

  void toggleSelection(String connectionId) {
    if (_running) return;
    if (!_selectedConnectionIds.remove(connectionId)) {
      _selectedConnectionIds.add(connectionId);
    }
    _invalidateSelectionCache();
    notifyListeners();
  }

  void clearSelection() {
    if (_running || _selectedConnectionIds.isEmpty) return;
    _selectedConnectionIds.clear();
    _invalidateSelectionCache();
    notifyListeners();
  }

  Future<void> startMonitoring({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    Map<String, ssh_core.SshTargetBinding>? targetBindings,
  }) async {
    if (_selectedConnectionIds.isEmpty) return;
    if (targetBindings != null) {
      final selected = _selectedConnectionIds.toSet();
      if (targetBindings.keys.toSet().length != selected.length ||
          !targetBindings.keys.toSet().containsAll(selected)) {
        throw StateError(
          'The performance monitor selection changed after approval.',
        );
      }
      _monitoringTargetBindings =
          Map<String, ssh_core.SshTargetBinding>.unmodifiable({
            for (final id in selected) id: targetBindings[id]!,
          });
    } else {
      _monitoringTargetBindings = null;
    }
    _running = true;
    _startedAt = DateTime.now();
    _monitoringConnectionIds
      ..clear()
      ..addAll(_selectedConnectionIds);
    _sampleStore.resetForMonitoring(_monitoringConnectionIds);
    _failureCountsByConnection.clear();
    _invalidateMonitoringCache();
    notifyListeners();

    // Keep the injected foreground capability active while monitoring. The
    // monitor stays App-scoped, so leaving a page does not stop sampling.
    final background = _background;
    if (background != null) {
      unawaited(background.start(connectionName: 'Performance monitor'));
    }
    _restartTimer();
    await sampleNow(onUnknownHostKey: onUnknownHostKey);
  }

  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _startedAt = null;
    _samplingConnectionIds.clear();
    _monitoringConnectionIds.clear();
    _monitoringTargetBindings = null;
    _sampleStore.stopMonitoring();
    _failureCountsByConnection.clear();
    _invalidateMonitoringCache();
    notifyListeners();
  }

  void stopForConnection(String connectionId) {
    final changed =
        _selectedConnectionIds.remove(connectionId) |
        _monitoringConnectionIds.remove(connectionId);
    _samplingConnectionIds.remove(connectionId);
    _sampleStore.removeConnection(connectionId);
    _failureCountsByConnection.remove(connectionId);
    _invalidateSelectionCache();
    _invalidateMonitoringCache();
    if (_monitoringConnectionIds.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _running = false;
      _startedAt = null;
    }
    if (changed) notifyListeners();
  }

  void setInterval(Duration interval) {
    if (_interval == interval) return;
    _interval = interval;
    if (_running) _restartTimer();
    notifyListeners();
  }

  void setHistoryWindow(Duration window) {
    final next = window > maxRetention ? maxRetention : window;
    if (_sampleStore.historyWindow == next) return;
    _sampleStore.setHistoryWindow(next);
    notifyListeners();
  }

  Future<void> sampleNow({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (!_running || _monitoringConnectionIds.isEmpty) return;
    final targets = _monitoringConnectionIds
        .where((id) => !_samplingConnectionIds.contains(id))
        .toList(growable: false);
    if (targets.isEmpty) return;
    _samplingConnectionIds.addAll(targets);
    if (!_disposed) notifyListeners();

    try {
      for (var index = 0; index < targets.length; index += 2) {
        final batch = targets.skip(index).take(2);
        await Future.wait(
          batch.map(
            (connectionId) => _sampleConnection(
              connectionId,
              onUnknownHostKey: onUnknownHostKey,
            ),
          ),
        );
      }
    } finally {
      _samplingConnectionIds.removeAll(targets);
      if (_running && !_disposed) _restartTimer();
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _sampleConnection(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    try {
      if (_platformFor(connectionId) == ServerPlatform.windows) {
        await _sampleWindowsConnection(
          connectionId,
          onUnknownHostKey: onUnknownHostKey,
        );
        return;
      }
      final result = await _runOneShotWithRetry(
        connectionId: connectionId,
        command: ServerStatusProbe.performanceCommand,
        timeout: _commandTimeout,
        onUnknownHostKey: onUnknownHostKey,
      );
      if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
        throw StateError(
          result.stderr.trim().isEmpty
              ? 'Performance command exited with ${result.exitCode}'
              : result.stderr.trim(),
        );
      }
      final raw = await ServerStatusProbe.parsePerformanceOutputAsync(
        result.stdout,
      );
      final sample = _sampleStore.sampleFromCounters(
        connectionId,
        raw.counters,
        DateTime.now(),
        raw.diskUsage,
        _interval,
      );
      if (!_running || !_monitoringConnectionIds.contains(connectionId)) {
        return;
      }
      _sampleStore.recordSample(
        connectionId,
        sample,
        raw.diskUsage,
        counters: raw.counters,
      );
      _failureCountsByConnection.remove(connectionId);
      _alertEvaluator.evaluate(connectionId, sample, raw.diskUsage);
    } catch (e, stackTrace) {
      _sampleStore.recordError(connectionId, e.toString());
      _failureCountsByConnection[connectionId] =
          (_failureCountsByConnection[connectionId] ?? 0) + 1;
      _alertEvaluator.recordSamplingFailure(connectionId, e.toString());
      _logger.warning(
        'Performance sample failed',
        details: 'connectionId=$connectionId error=$e',
      );
      _logger.error(
        'Performance sample stack trace',
        error: e,
        stackTrace: stackTrace,
        details: 'connectionId=$connectionId',
      );
    }
  }

  Future<void> _sampleWindowsConnection(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final status = await _fetchWindowsStatus(
      connectionId,
      _commandTimeout,
      onUnknownHostKey: onUnknownHostKey,
    );
    final sample = PerformanceSample(
      connectionId: connectionId,
      time: DateTime.now(),
      cpuPercent: status.cpuPercent,
      memoryPercent: status.memoryPercent,
      diskBytesPerSecond: status.diskBytesPerSecond,
      networkBytesPerSecond: status.networkBytesPerSecond,
      diskUsage: status.diskUsage,
    );
    if (!_running || !_monitoringConnectionIds.contains(connectionId)) {
      return;
    }
    _sampleStore.recordSample(connectionId, sample, status.diskUsage);
    _failureCountsByConnection.remove(connectionId);
    _alertEvaluator.evaluate(connectionId, sample, status.diskUsage);
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_effectiveInterval, (_) => unawaited(sampleNow()));
  }

  Duration get _effectiveInterval {
    var multiplier = 1;
    for (final count in _failureCountsByConnection.values) {
      multiplier = max(multiplier, 1 << min(count, 4));
    }
    final next = _interval * multiplier;
    return next > const Duration(minutes: 5)
        ? const Duration(minutes: 5)
        : next;
  }

  Duration get _commandTimeout {
    final seconds = max(6, min(_effectiveInterval.inSeconds - 1, 30));
    return Duration(seconds: seconds);
  }

  Future<List<PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (_platformFor(connectionId) == ServerPlatform.windows) {
      return (await _fetchWindowsStatus(
        connectionId,
        const Duration(seconds: 20),
        onUnknownHostKey: onUnknownHostKey,
      )).ports;
    }
    final result = await _runOneShotWithRetry(
      connectionId: connectionId,
      command: ServerStatusProbe.portsCommand,
      timeout: const Duration(seconds: 12),
      onUnknownHostKey: onUnknownHostKey,
    );
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      throw StateError(result.stderr.trim());
    }
    return ServerStatusProbe.parsePortsAsync(result.stdout);
  }

  Future<List<ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (_platformFor(connectionId) == ServerPlatform.windows) {
      return (await _fetchWindowsStatus(
        connectionId,
        const Duration(seconds: 20),
        onUnknownHostKey: onUnknownHostKey,
      )).applications;
    }
    final result = await _runOneShotWithRetry(
      connectionId: connectionId,
      command: ServerStatusProbe.applicationsCommand,
      timeout: const Duration(seconds: 12),
      onUnknownHostKey: onUnknownHostKey,
    );
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      throw StateError(result.stderr.trim());
    }
    return ServerStatusProbe.parseApplicationsAsync(result.stdout);
  }

  Future<List<ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (_platformFor(connectionId) == ServerPlatform.windows) {
      return (await _fetchWindowsStatus(
        connectionId,
        const Duration(seconds: 20),
        onUnknownHostKey: onUnknownHostKey,
      )).services;
    }
    final result = await _runOneShotWithRetry(
      connectionId: connectionId,
      command: ServerStatusProbe.servicesCommand,
      timeout: const Duration(seconds: 12),
      onUnknownHostKey: onUnknownHostKey,
    );
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      throw StateError(result.stderr.trim());
    }
    return ServerStatusProbe.parseServicesAsync(result.stdout);
  }

  Future<WindowsStatusSnapshot> _fetchWindowsStatus(
    String connectionId,
    Duration timeout, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final result = await _runOneShotWithRetry(
      connectionId: connectionId,
      command: ServerStatusProbe.windowsStatusCommand,
      timeout: timeout,
      onUnknownHostKey: onUnknownHostKey,
    );
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      throw StateError(
        result.stderr.trim().isEmpty
            ? 'Windows status command exited with ${result.exitCode}'
            : result.stderr.trim(),
      );
    }
    return ServerStatusProbe.parseWindowsStatusAsync(result.stdout);
  }

  ServerPlatform _platformFor(String connectionId) {
    final bound = _monitoringTargetBindings?[connectionId];
    if (bound != null) return bound.serverPlatform;
    return _connectionCatalog.serverPlatformFor(connectionId) ??
        ServerPlatform.linux;
  }

  Future<ssh_core.RemoteCommandResult> _runOneShotWithRetry({
    required String connectionId,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    Future<ssh_core.RemoteCommandResult> run() {
      final binding = _monitoringTargetBindings?[connectionId];
      if (_monitoringTargetBindings != null && binding == null) {
        throw StateError(
          'Connection is not part of the approved monitor target set.',
        );
      }
      return binding == null
          ? _sshPort.runOneShotCommand(
              connectionId: connectionId,
              command: command,
              timeout: timeout,
              onUnknownHostKey: onUnknownHostKey,
              priority: MonitoringRequestPriority.low,
            )
          : _sshPort.runOneShotCommandForBinding(
              binding: binding,
              command: command,
              timeout: timeout,
              onUnknownHostKey: onUnknownHostKey,
              priority: MonitoringRequestPriority.low,
            );
    }

    try {
      return await run();
    } catch (firstError, firstStackTrace) {
      if (_disposed) {
        Error.throwWithStackTrace(firstError, firstStackTrace);
      }
      _logger.warning(
        'Retrying one-shot SSH command after interruption',
        details: 'connectionId=$connectionId error=$firstError',
      );
      await Future<void>.delayed(_retryDelayFor(connectionId));
      if (_disposed) {
        Error.throwWithStackTrace(firstError, firstStackTrace);
      }
      try {
        return await run();
      } catch (retryError) {
        throw StateError(
          'SSH reconnect failed after interruption: $retryError '
          '(first error: $firstError)',
        );
      }
    }
  }

  Duration _retryDelayFor(String connectionId) {
    final failures = _failureCountsByConnection[connectionId] ?? 0;
    return Duration(milliseconds: 700 + min(failures, 4) * 350);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
