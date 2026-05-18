import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/connection.dart';
import 'app_log_service.dart';
import 'background_service.dart';
import 'server_status_probe.dart';
import 'ssh_service.dart';
import 'storage_service.dart';

class PerformanceMonitorService extends ChangeNotifier {
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

  final SshService _sshService;
  final StorageService _storageService;
  Timer? _timer;
  bool _disposed = false;
  bool _running = false;
  DateTime? _startedAt;
  Duration _interval = defaultInterval;
  Duration _historyWindow = defaultHistoryWindow;
  final Set<String> _selectedConnectionIds = {};
  final Set<String> _monitoringConnectionIds = {};
  final Set<String> _samplingConnectionIds = {};
  final Map<String, List<PerformanceSample>> _samplesByConnection = {};
  final Map<String, List<DiskUsageSnapshot>> _diskUsageByConnection = {};
  final Map<String, String> _errorsByConnection = {};
  final Map<String, int> _failureCountsByConnection = {};
  final Map<String, RawPerformanceCounters> _previousCountersByConnection = {};
  final Map<String, DateTime> _lastAlertAtByKey = {};
  final List<MonitorAlert> _alerts = [];
  Set<String>? _selectedConnectionIdsView;
  Set<String>? _monitoringConnectionIdsView;
  Map<String, String>? _errorsByConnectionView;
  List<MonitorAlert>? _alertsView;
  Map<String, ServerHealthSnapshot>? _healthByConnectionView;
  final Map<String, ServerHealthSnapshot> _healthByConnectionEntryCache = {};
  final Map<String, List<DiskUsageSnapshot>> _diskUsageViewsByConnection = {};
  final Map<String, List<PerformanceSample>> _sampleViewsByConnection = {};
  final Map<String, List<PerformanceSample>> _visibleSamplesByConnection = {};
  DateTime? _visibleSamplesCutoff;
  int? _visibleSamplesCutoffBucket;
  Duration? _visibleSamplesWindow;

  PerformanceMonitorService(this._sshService, this._storageService);

  bool get isRunning => _running;
  bool get isSampling => _samplingConnectionIds.isNotEmpty;
  Duration get interval => _interval;
  Duration get effectiveInterval => _effectiveInterval;
  Duration get historyWindow => _historyWindow;
  DateTime? get startedAt => _startedAt;
  Set<String> get selectedConnectionIds =>
      _selectedConnectionIdsView ??= Set.unmodifiable(_selectedConnectionIds);
  Set<String> get monitoringConnectionIds => _monitoringConnectionIdsView ??=
      Set.unmodifiable(_monitoringConnectionIds);
  Map<String, String> get errorsByConnection =>
      _errorsByConnectionView ??= Map.unmodifiable(_errorsByConnection);
  List<MonitorAlert> get alerts => _alertsView ??= List.unmodifiable(_alerts);
  Map<String, ServerHealthSnapshot> get healthByConnection {
    final cached = _healthByConnectionView;
    if (cached != null) return cached;
    final ids = {
      ..._selectedConnectionIds,
      ..._monitoringConnectionIds,
      ..._samplesByConnection.keys,
      ..._errorsByConnection.keys,
    };
    return _healthByConnectionView = Map.unmodifiable({
      for (final id in ids) id: _buildHealthFor(id),
    });
  }

  List<DiskUsageSnapshot> diskUsageFor(String connectionId) {
    return _diskUsageViewsByConnection[connectionId] ??= List.unmodifiable(
      _diskUsageByConnection[connectionId] ?? const <DiskUsageSnapshot>[],
    );
  }

  List<PerformanceSample> samplesFor(String connectionId) {
    return _sampleViewsByConnection[connectionId] ??= List.unmodifiable(
      _samplesByConnection[connectionId] ?? const <PerformanceSample>[],
    );
  }

  ServerHealthSnapshot healthFor(String connectionId) {
    final cached = _healthByConnectionView?[connectionId];
    if (cached != null) return cached;
    return _healthByConnectionEntryCache[connectionId] ??=
        _buildHealthFor(connectionId);
  }

  ServerHealthSnapshot _buildHealthFor(String connectionId) {
    final error = _errorsByConnection[connectionId];
    final samples = _samplesByConnection[connectionId] ?? const [];
    if (error != null && error.isNotEmpty) {
      return ServerHealthSnapshot(
        connectionId: connectionId,
        level: ServerHealthLevel.critical,
        score: 0,
        summary: 'Sampling failed',
        details: [error],
        updatedAt: DateTime.now(),
      );
    }
    if (samples.isEmpty) {
      return ServerHealthSnapshot(
        connectionId: connectionId,
        level: ServerHealthLevel.unknown,
        score: 0,
        summary: 'No samples',
        details: const [],
        updatedAt: DateTime.now(),
      );
    }
    final sample = samples.last;
    final diskMax = sample.diskUsage.isEmpty
        ? 0.0
        : sample.diskUsage.map((disk) => disk.usedPercent).reduce(max);
    final details = <String>[];
    final cpuPenalty = _thresholdPenalty(sample.cpuPercent, 70, 95, 35);
    final memoryPenalty = _thresholdPenalty(sample.memoryPercent, 70, 95, 35);
    final diskPenalty = _thresholdPenalty(diskMax, 75, 95, 30);
    final score =
        (100 - cpuPenalty - memoryPenalty - diskPenalty).clamp(0, 100).round();
    if (sample.cpuPercent >= 85) {
      details.add('CPU ${sample.cpuPercent.toStringAsFixed(1)}%');
    }
    if (sample.memoryPercent >= 85) {
      details.add('Memory ${sample.memoryPercent.toStringAsFixed(1)}%');
    }
    if (diskMax >= 85) {
      details.add('Disk ${diskMax.toStringAsFixed(1)}%');
    }
    final level = score < 45 ||
            sample.cpuPercent >= 95 ||
            sample.memoryPercent >= 95 ||
            diskMax >= 95
        ? ServerHealthLevel.critical
        : score < 75 ||
                sample.cpuPercent >= 85 ||
                sample.memoryPercent >= 85 ||
                diskMax >= 85
            ? ServerHealthLevel.warning
            : ServerHealthLevel.healthy;
    return ServerHealthSnapshot(
      connectionId: connectionId,
      level: level,
      score: score,
      summary: switch (level) {
        ServerHealthLevel.healthy => 'Healthy',
        ServerHealthLevel.warning => 'Warning',
        ServerHealthLevel.critical => 'Critical',
        ServerHealthLevel.unknown => 'No samples',
      },
      details: details,
      updatedAt: sample.time,
      latestSample: sample,
      maxDiskUsedPercent: diskMax,
    );
  }

  List<PerformanceSample> visibleSamplesFor(String connectionId) {
    final cutoff = DateTime.now().subtract(_historyWindow);
    final cutoffBucket = cutoff.millisecondsSinceEpoch ~/ 1000;
    if (_visibleSamplesWindow != _historyWindow ||
        _visibleSamplesCutoffBucket != cutoffBucket) {
      _visibleSamplesByConnection.clear();
      _visibleSamplesWindow = _historyWindow;
      _visibleSamplesCutoffBucket = cutoffBucket;
      _visibleSamplesCutoff = cutoff;
    }
    final activeCutoff = _visibleSamplesCutoff ?? cutoff;
    return _visibleSamplesByConnection[connectionId] ??= List.unmodifiable(
      (_samplesByConnection[connectionId] ?? const <PerformanceSample>[])
          .where((sample) => !sample.time.isBefore(activeCutoff)),
    );
  }

  // Sampling widgets read these snapshots several times per build. Keep stable
  // immutable views and invalidate only the affected connection when data moves.
  void _invalidateSelectionCache() {
    _selectedConnectionIdsView = null;
    _healthByConnectionView = null;
  }

  void _invalidateMonitoringCache() {
    _monitoringConnectionIdsView = null;
    _healthByConnectionView = null;
  }

  void _invalidateErrorsCache([String? connectionId]) {
    _errorsByConnectionView = null;
    _healthByConnectionView = null;
    if (connectionId == null) {
      _healthByConnectionEntryCache.clear();
    } else {
      _healthByConnectionEntryCache.remove(connectionId);
    }
  }

  void _invalidateSamplesFor(String connectionId) {
    _sampleViewsByConnection.remove(connectionId);
    _visibleSamplesByConnection.remove(connectionId);
    _healthByConnectionView = null;
    _healthByConnectionEntryCache.remove(connectionId);
  }

  void _invalidateAllSamplesCache() {
    _sampleViewsByConnection.clear();
    _invalidateVisibleSamplesCache();
    _healthByConnectionView = null;
    _healthByConnectionEntryCache.clear();
  }

  void _invalidateVisibleSamplesCache() {
    _visibleSamplesByConnection.clear();
    _visibleSamplesCutoff = null;
    _visibleSamplesCutoffBucket = null;
    _visibleSamplesWindow = null;
  }

  void _invalidateDiskUsageFor(String connectionId) {
    _diskUsageViewsByConnection.remove(connectionId);
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

  Future<void> startMonitoring() async {
    if (_selectedConnectionIds.isEmpty) return;
    _running = true;
    _startedAt = DateTime.now();
    _monitoringConnectionIds
      ..clear()
      ..addAll(_selectedConnectionIds);
    _samplesByConnection
      ..clear()
      ..addEntries(
        _monitoringConnectionIds
            .map((id) => MapEntry(id, <PerformanceSample>[])),
      );
    _errorsByConnection.clear();
    _failureCountsByConnection.clear();
    _previousCountersByConnection.clear();
    _invalidateMonitoringCache();
    _invalidateErrorsCache();
    _invalidateAllSamplesCache();
    notifyListeners();

    // Keep the app's foreground service and power locks active while monitoring.
    // The monitor stays app-scoped, so leaving the page does not stop sampling.
    unawaited(
      BackgroundServiceManager.start(connectionName: 'Performance monitor'),
    );
    _restartTimer();
    await sampleNow();
  }

  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _startedAt = null;
    _samplingConnectionIds.clear();
    _monitoringConnectionIds.clear();
    _errorsByConnection.clear();
    _failureCountsByConnection.clear();
    _previousCountersByConnection.clear();
    _invalidateMonitoringCache();
    _invalidateErrorsCache();
    notifyListeners();
  }

  void stopForConnection(String connectionId) {
    final changed = _selectedConnectionIds.remove(connectionId) |
        _monitoringConnectionIds.remove(connectionId);
    _samplingConnectionIds.remove(connectionId);
    _samplesByConnection.remove(connectionId);
    _errorsByConnection.remove(connectionId);
    _diskUsageByConnection.remove(connectionId);
    _failureCountsByConnection.remove(connectionId);
    _previousCountersByConnection.remove(connectionId);
    _invalidateSelectionCache();
    _invalidateMonitoringCache();
    _invalidateErrorsCache(connectionId);
    _invalidateSamplesFor(connectionId);
    _invalidateDiskUsageFor(connectionId);
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
    if (_historyWindow == next) return;
    _historyWindow = next;
    _invalidateVisibleSamplesCache();
    notifyListeners();
  }

  Future<void> sampleNow() async {
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
        await Future.wait(batch.map(_sampleConnection));
      }
    } finally {
      _samplingConnectionIds.removeAll(targets);
      if (_running && !_disposed) _restartTimer();
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _sampleConnection(String connectionId) async {
    try {
      if (_platformFor(connectionId) == ServerPlatform.windows) {
        await _sampleWindowsConnection(connectionId);
        return;
      }
      final result = await _runOneShotWithRetry(
        connectionId: connectionId,
        command: ServerStatusProbe.performanceCommand,
        timeout: _commandTimeout,
      );
      if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
        throw StateError(
          result.stderr.trim().isEmpty
              ? 'Performance command exited with ${result.exitCode}'
              : result.stderr.trim(),
        );
      }
      final raw = ServerStatusProbe.parsePerformanceOutput(result.stdout);
      final sample = _sampleFromCounters(
        connectionId,
        raw.counters,
        DateTime.now(),
        raw.diskUsage,
      );
      if (!_running || !_monitoringConnectionIds.contains(connectionId)) {
        return;
      }
      _previousCountersByConnection[connectionId] = raw.counters;
      _diskUsageByConnection[connectionId] = raw.diskUsage;
      (_samplesByConnection[connectionId] ??= []).add(sample);
      _trimSamples(connectionId);
      final hadError = _errorsByConnection.remove(connectionId) != null;
      _failureCountsByConnection.remove(connectionId);
      _evaluateAlerts(connectionId, sample, raw.diskUsage);
      _invalidateSamplesFor(connectionId);
      _invalidateDiskUsageFor(connectionId);
      if (hadError) _invalidateErrorsCache(connectionId);
    } catch (e, stackTrace) {
      _errorsByConnection[connectionId] = e.toString();
      _failureCountsByConnection[connectionId] =
          (_failureCountsByConnection[connectionId] ?? 0) + 1;
      _addAlert(
        connectionId: connectionId,
        metric: 'sampling',
        level: ServerHealthLevel.critical,
        message: 'Sampling failed: $e',
      );
      _invalidateErrorsCache(connectionId);
      AppLogService.instance.warning(
        'Performance sample failed',
        details: 'connectionId=$connectionId error=$e',
      );
      debugPrint('Performance sample failed: $e\n$stackTrace');
    }
  }

  Future<void> _sampleWindowsConnection(String connectionId) async {
    final status = await _fetchWindowsStatus(connectionId, _commandTimeout);
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
    _diskUsageByConnection[connectionId] = status.diskUsage;
    (_samplesByConnection[connectionId] ??= []).add(sample);
    _trimSamples(connectionId);
    final hadError = _errorsByConnection.remove(connectionId) != null;
    _failureCountsByConnection.remove(connectionId);
    _evaluateAlerts(connectionId, sample, status.diskUsage);
    _invalidateSamplesFor(connectionId);
    _invalidateDiskUsageFor(connectionId);
    if (hadError) _invalidateErrorsCache(connectionId);
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      _effectiveInterval,
      (_) => unawaited(sampleNow()),
    );
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

  Future<List<PortProcessSnapshot>> fetchPorts(String connectionId) async {
    if (_platformFor(connectionId) == ServerPlatform.windows) {
      return (await _fetchWindowsStatus(
        connectionId,
        const Duration(seconds: 20),
      ))
          .ports;
    }
    final result = await _runOneShotWithRetry(
      connectionId: connectionId,
      command: ServerStatusProbe.portsCommand,
      timeout: const Duration(seconds: 12),
    );
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      throw StateError(result.stderr.trim());
    }
    return ServerStatusProbe.parsePorts(result.stdout);
  }

  Future<List<ApplicationMemorySnapshot>> fetchApplications(
    String connectionId,
  ) async {
    if (_platformFor(connectionId) == ServerPlatform.windows) {
      return (await _fetchWindowsStatus(
        connectionId,
        const Duration(seconds: 20),
      ))
          .applications;
    }
    final result = await _runOneShotWithRetry(
      connectionId: connectionId,
      command: ServerStatusProbe.applicationsCommand,
      timeout: const Duration(seconds: 12),
    );
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      throw StateError(result.stderr.trim());
    }
    return ServerStatusProbe.parseApplications(result.stdout);
  }

  Future<WindowsStatusSnapshot> _fetchWindowsStatus(
    String connectionId,
    Duration timeout,
  ) async {
    final result = await _runOneShotWithRetry(
      connectionId: connectionId,
      command: ServerStatusProbe.windowsStatusCommand,
      timeout: timeout,
    );
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      throw StateError(
        result.stderr.trim().isEmpty
            ? 'Windows status command exited with ${result.exitCode}'
            : result.stderr.trim(),
      );
    }
    return ServerStatusProbe.parseWindowsStatus(result.stdout);
  }

  ServerPlatform _platformFor(String connectionId) {
    return _storageService.getConnection(connectionId)?.serverPlatform ??
        ServerPlatform.linux;
  }

  Future<RemoteCommandResult> _runOneShotWithRetry({
    required String connectionId,
    required String command,
    required Duration timeout,
  }) async {
    try {
      return await _sshService.runOneShotCommand(
        connectionId: connectionId,
        command: command,
        timeout: timeout,
      );
    } catch (firstError, firstStackTrace) {
      if (_disposed) {
        Error.throwWithStackTrace(firstError, firstStackTrace);
      }
      AppLogService.instance.warning(
        'Retrying one-shot SSH command after interruption',
        details: 'connectionId=$connectionId error=$firstError',
      );
      await Future<void>.delayed(_retryDelayFor(connectionId));
      if (_disposed) {
        Error.throwWithStackTrace(firstError, firstStackTrace);
      }
      try {
        return await _sshService.runOneShotCommand(
          connectionId: connectionId,
          command: command,
          timeout: timeout,
        );
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

  PerformanceSample _sampleFromCounters(
    String connectionId,
    RawPerformanceCounters counters,
    DateTime time,
    List<DiskUsageSnapshot> diskUsage,
  ) {
    final previous = _previousCountersByConnection[connectionId];
    final cpuPercent = previous == null
        ? 0.0
        : _ratePercent(
            counters.cpuTotal - previous.cpuTotal,
            counters.cpuBusy - previous.cpuBusy,
          );
    final seconds = previous == null
        ? _interval.inMilliseconds / 1000
        : max(0.001, time.difference(previous.time).inMilliseconds / 1000);
    final diskBytesPerSecond = previous == null
        ? 0.0
        : (counters.diskBytes - previous.diskBytes) / seconds;
    final networkBytesPerSecond = previous == null
        ? 0.0
        : (counters.networkBytes - previous.networkBytes) / seconds;

    return PerformanceSample(
      connectionId: connectionId,
      time: time,
      cpuPercent: cpuPercent.clamp(0, 100).toDouble(),
      memoryPercent: counters.memoryPercent.clamp(0, 100).toDouble(),
      diskBytesPerSecond: max(0, diskBytesPerSecond),
      networkBytesPerSecond: max(0, networkBytesPerSecond),
      diskUsage: diskUsage,
    );
  }

  double _ratePercent(int totalDelta, int busyDelta) {
    if (totalDelta <= 0 || busyDelta <= 0) return 0;
    return busyDelta / totalDelta * 100;
  }

  void _trimSamples(String connectionId) {
    final cutoff = DateTime.now().subtract(maxRetention);
    _samplesByConnection[connectionId]
        ?.removeWhere((sample) => sample.time.isBefore(cutoff));
  }

  double _thresholdPenalty(
    double value,
    double warning,
    double critical,
    double maxPenalty,
  ) {
    if (value <= warning) return 0;
    if (value >= critical) return maxPenalty;
    return (value - warning) / (critical - warning) * maxPenalty;
  }

  void _evaluateAlerts(
    String connectionId,
    PerformanceSample sample,
    List<DiskUsageSnapshot> diskUsage,
  ) {
    _thresholdAlert(
      connectionId: connectionId,
      metric: 'cpu',
      label: 'CPU',
      value: sample.cpuPercent,
      warning: 85,
      critical: 95,
    );
    _thresholdAlert(
      connectionId: connectionId,
      metric: 'memory',
      label: 'Memory',
      value: sample.memoryPercent,
      warning: 85,
      critical: 95,
    );
    for (final disk in diskUsage) {
      _thresholdAlert(
        connectionId: connectionId,
        metric: 'disk:${disk.mount}',
        label: 'Disk ${disk.mount}',
        value: disk.usedPercent,
        warning: 85,
        critical: 95,
      );
    }
  }

  void _thresholdAlert({
    required String connectionId,
    required String metric,
    required String label,
    required double value,
    required double warning,
    required double critical,
  }) {
    if (value >= critical) {
      _addAlert(
        connectionId: connectionId,
        metric: metric,
        level: ServerHealthLevel.critical,
        message: '$label is ${value.toStringAsFixed(1)}%',
      );
    } else if (value >= warning) {
      _addAlert(
        connectionId: connectionId,
        metric: metric,
        level: ServerHealthLevel.warning,
        message: '$label is ${value.toStringAsFixed(1)}%',
      );
    }
  }

  void _addAlert({
    required String connectionId,
    required String metric,
    required ServerHealthLevel level,
    required String message,
  }) {
    final now = DateTime.now();
    final key = '$connectionId:$metric:${level.name}';
    final lastAt = _lastAlertAtByKey[key];
    if (lastAt != null && now.difference(lastAt) < const Duration(minutes: 5)) {
      return;
    }
    _lastAlertAtByKey[key] = now;
    _alerts.insert(
      0,
      MonitorAlert(
        id: '${now.microsecondsSinceEpoch}-$key',
        connectionId: connectionId,
        metric: metric,
        level: level,
        message: message,
        createdAt: now,
      ),
    );
    if (_alerts.length > 80) {
      _alerts.removeRange(80, _alerts.length);
    }
    _alertsView = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

enum ServerHealthLevel { unknown, healthy, warning, critical }

class ServerHealthSnapshot {
  final String connectionId;
  final ServerHealthLevel level;
  final int score;
  final String summary;
  final List<String> details;
  final DateTime updatedAt;
  final PerformanceSample? latestSample;
  final double maxDiskUsedPercent;

  const ServerHealthSnapshot({
    required this.connectionId,
    required this.level,
    required this.score,
    required this.summary,
    required this.details,
    required this.updatedAt,
    this.latestSample,
    this.maxDiskUsedPercent = 0,
  });

  Map<String, dynamic> toJson() => {
        'connectionId': connectionId,
        'level': level.name,
        'score': score,
        'summary': summary,
        'details': details,
        'updatedAt': updatedAt.toIso8601String(),
        'maxDiskUsedPercent': maxDiskUsedPercent,
        if (latestSample != null)
          'latestSample': {
            'cpuPercent': latestSample!.cpuPercent,
            'memoryPercent': latestSample!.memoryPercent,
            'diskBytesPerSecond': latestSample!.diskBytesPerSecond,
            'networkBytesPerSecond': latestSample!.networkBytesPerSecond,
          },
      };
}

class MonitorAlert {
  final String id;
  final String connectionId;
  final String metric;
  final ServerHealthLevel level;
  final String message;
  final DateTime createdAt;

  const MonitorAlert({
    required this.id,
    required this.connectionId,
    required this.metric,
    required this.level,
    required this.message,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'connectionId': connectionId,
        'metric': metric,
        'level': level.name,
        'message': message,
        'createdAt': createdAt.toIso8601String(),
      };
}

class PerformanceSample {
  final String connectionId;
  final DateTime time;
  final double cpuPercent;
  final double memoryPercent;
  final double diskBytesPerSecond;
  final double networkBytesPerSecond;
  final List<DiskUsageSnapshot> diskUsage;

  const PerformanceSample({
    required this.connectionId,
    required this.time,
    required this.cpuPercent,
    required this.memoryPercent,
    required this.diskBytesPerSecond,
    required this.networkBytesPerSecond,
    this.diskUsage = const [],
  });
}
