// 监控阈值、去重窗口和告警上限的独立 Owner。

import '../domain/monitoring_models.dart';
import 'monitoring_sample_store.dart';

/// 独占告警阈值解释、五分钟去重和有界历史。
final class MonitoringAlertEvaluator {
  MonitoringAlertEvaluator({MonitoringClock? clock})
    : _clock = clock ?? DateTime.now;

  final MonitoringClock _clock;
  final Map<String, DateTime> _lastAlertAt = {};
  final List<MonitorAlert> _alerts = [];
  List<MonitorAlert>? _view;

  List<MonitorAlert> get alerts => _view ??= List.unmodifiable(_alerts);

  void evaluate(
    String connectionId,
    PerformanceSample sample,
    List<DiskUsageSnapshot> diskUsage,
  ) {
    _threshold(
      connectionId: connectionId,
      metric: 'cpu',
      label: 'CPU',
      value: sample.cpuPercent,
    );
    _threshold(
      connectionId: connectionId,
      metric: 'memory',
      label: 'Memory',
      value: sample.memoryPercent,
    );
    for (final disk in diskUsage) {
      _threshold(
        connectionId: connectionId,
        metric: 'disk:${disk.mount}',
        label: 'Disk ${disk.mount}',
        value: disk.usedPercent,
      );
    }
  }

  void recordSamplingFailure(String connectionId, String error) {
    _add(
      connectionId: connectionId,
      metric: 'sampling',
      level: ServerHealthLevel.critical,
      message: 'Sampling failed: $error',
    );
  }

  void _threshold({
    required String connectionId,
    required String metric,
    required String label,
    required double value,
  }) {
    if (value >= 95) {
      _add(
        connectionId: connectionId,
        metric: metric,
        level: ServerHealthLevel.critical,
        message: '$label is ${value.toStringAsFixed(1)}%',
      );
    } else if (value >= 85) {
      _add(
        connectionId: connectionId,
        metric: metric,
        level: ServerHealthLevel.warning,
        message: '$label is ${value.toStringAsFixed(1)}%',
      );
    }
  }

  void _add({
    required String connectionId,
    required String metric,
    required ServerHealthLevel level,
    required String message,
  }) {
    final now = _clock();
    final key = '$connectionId:$metric:${level.name}';
    final lastAt = _lastAlertAt[key];
    if (lastAt != null && now.difference(lastAt) < const Duration(minutes: 5)) {
      return;
    }
    _lastAlertAt[key] = now;
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
    if (_alerts.length > 80) _alerts.removeRange(80, _alerts.length);
    _view = null;
  }
}
