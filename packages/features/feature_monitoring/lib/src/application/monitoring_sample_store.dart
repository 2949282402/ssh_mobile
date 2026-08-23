// 监控采样历史、派生视图和健康评分的内存 Owner。

import 'dart:math';

import '../domain/monitoring_models.dart';

typedef MonitoringClock = DateTime Function();

/// 独占受限采样窗口、累计计数和不可变派生视图。
final class MonitoringSampleStore {
  MonitoringSampleStore({
    required this.historyWindow,
    required this.maxRetention,
    MonitoringClock? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration maxRetention;
  final MonitoringClock _clock;
  Duration historyWindow;

  final Map<String, List<PerformanceSample>> _samples = {};
  final Map<String, List<DiskUsageSnapshot>> _diskUsage = {};
  final Map<String, String> _errors = {};
  final Map<String, RawPerformanceCounters> _previousCounters = {};
  final Map<String, ServerHealthSnapshot> _healthEntries = {};
  final Map<String, List<DiskUsageSnapshot>> _diskViews = {};
  final Map<String, List<PerformanceSample>> _sampleViews = {};
  final Map<String, List<PerformanceSample>> _visibleSamples = {};
  Map<String, String>? _errorsView;
  Map<String, ServerHealthSnapshot>? _healthView;
  DateTime? _visibleCutoff;
  int? _visibleCutoffBucket;
  Duration? _visibleWindow;

  Map<String, String> get errors => _errorsView ??= Map.unmodifiable(_errors);

  void setHistoryWindow(Duration window) {
    if (historyWindow == window) return;
    historyWindow = window;
    _invalidateVisible();
  }

  List<DiskUsageSnapshot> diskUsageFor(String connectionId) =>
      _diskViews[connectionId] ??= List.unmodifiable(
        _diskUsage[connectionId] ?? const <DiskUsageSnapshot>[],
      );

  List<PerformanceSample> samplesFor(String connectionId) =>
      _sampleViews[connectionId] ??= List.unmodifiable(
        _samples[connectionId] ?? const <PerformanceSample>[],
      );

  List<PerformanceSample> visibleSamplesFor(String connectionId) {
    final cutoff = _clock().subtract(historyWindow);
    final cutoffBucket = cutoff.millisecondsSinceEpoch ~/ 1000;
    if (_visibleWindow != historyWindow ||
        _visibleCutoffBucket != cutoffBucket) {
      _visibleSamples.clear();
      _visibleWindow = historyWindow;
      _visibleCutoffBucket = cutoffBucket;
      _visibleCutoff = cutoff;
    }
    final activeCutoff = _visibleCutoff ?? cutoff;
    return _visibleSamples[connectionId] ??= List.unmodifiable(
      (_samples[connectionId] ?? const <PerformanceSample>[]).where(
        (sample) => !sample.time.isBefore(activeCutoff),
      ),
    );
  }

  ServerHealthSnapshot healthFor(String connectionId) =>
      _healthView?[connectionId] ??
      (_healthEntries[connectionId] ??= _buildHealth(connectionId));

  Map<String, ServerHealthSnapshot> healthForConnections(
    Iterable<String> connectionIds,
  ) {
    final cached = _healthView;
    if (cached != null) return cached;
    final ids = <String>{...connectionIds, ..._samples.keys, ..._errors.keys};
    return _healthView = Map.unmodifiable({
      for (final id in ids) id: _buildHealth(id),
    });
  }

  /// 连接选择集合变化时只撤销聚合 Map，不丢弃单连接缓存。
  void invalidateConnectionSet() {
    _healthView = null;
  }

  /// 新监控轮次清空历史与错误，但保持磁盘视图的原有兼容行为。
  void resetForMonitoring(Iterable<String> connectionIds) {
    _samples
      ..clear()
      ..addEntries(
        connectionIds.map((id) => MapEntry(id, <PerformanceSample>[])),
      );
    _errors.clear();
    _previousCounters.clear();
    _errorsView = null;
    _sampleViews.clear();
    _invalidateVisible();
    _invalidateHealth();
  }

  /// 停止轮询时清除瞬时错误和累计计数，保留最后历史供 UI 查看。
  void stopMonitoring() {
    _errors.clear();
    _previousCounters.clear();
    _errorsView = null;
    _invalidateHealth();
  }

  void removeConnection(String connectionId) {
    _samples.remove(connectionId);
    _errors.remove(connectionId);
    _diskUsage.remove(connectionId);
    _previousCounters.remove(connectionId);
    _errorsView = null;
    _sampleViews.remove(connectionId);
    _visibleSamples.remove(connectionId);
    _diskViews.remove(connectionId);
    _healthEntries.remove(connectionId);
    _healthView = null;
  }

  void recordError(String connectionId, String error) {
    _errors[connectionId] = error;
    _errorsView = null;
    _invalidateHealthFor(connectionId);
  }

  /// 保存一次已批准目标的采样，并返回此前是否存在错误。
  bool recordSample(
    String connectionId,
    PerformanceSample sample,
    List<DiskUsageSnapshot> diskUsage, {
    RawPerformanceCounters? counters,
  }) {
    if (counters != null) _previousCounters[connectionId] = counters;
    _diskUsage[connectionId] = diskUsage;
    (_samples[connectionId] ??= <PerformanceSample>[]).add(sample);
    _trimSamples(connectionId);
    final hadError = _errors.remove(connectionId) != null;
    if (hadError) _errorsView = null;
    _sampleViews.remove(connectionId);
    _visibleSamples.remove(connectionId);
    _diskViews.remove(connectionId);
    _invalidateHealthFor(connectionId);
    return hadError;
  }

  PerformanceSample sampleFromCounters(
    String connectionId,
    RawPerformanceCounters counters,
    DateTime time,
    List<DiskUsageSnapshot> diskUsage,
    Duration interval,
  ) {
    final previous = _previousCounters[connectionId];
    final cpuPercent = previous == null
        ? 0.0
        : _ratePercent(
            counters.cpuTotal - previous.cpuTotal,
            counters.cpuBusy - previous.cpuBusy,
          );
    final seconds = previous == null
        ? interval.inMilliseconds / 1000
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

  ServerHealthSnapshot _buildHealth(String connectionId) {
    final error = _errors[connectionId];
    final samples = _samples[connectionId] ?? const <PerformanceSample>[];
    if (error != null && error.isNotEmpty) {
      return ServerHealthSnapshot(
        connectionId: connectionId,
        level: ServerHealthLevel.critical,
        score: 0,
        summary: 'Sampling failed',
        details: <String>[error],
        updatedAt: _clock(),
      );
    }
    if (samples.isEmpty) {
      return ServerHealthSnapshot(
        connectionId: connectionId,
        level: ServerHealthLevel.unknown,
        score: 0,
        summary: 'No samples',
        details: const <String>[],
        updatedAt: _clock(),
      );
    }
    final sample = samples.last;
    final diskMax = sample.diskUsage.isEmpty
        ? 0.0
        : sample.diskUsage.map((disk) => disk.usedPercent).reduce(max);
    final details = <String>[];
    final score =
        (100 -
                _thresholdPenalty(sample.cpuPercent, 70, 95, 35) -
                _thresholdPenalty(sample.memoryPercent, 70, 95, 35) -
                _thresholdPenalty(diskMax, 75, 95, 30))
            .clamp(0, 100)
            .round();
    if (sample.cpuPercent >= 85) {
      details.add('CPU ${sample.cpuPercent.toStringAsFixed(1)}%');
    }
    if (sample.memoryPercent >= 85) {
      details.add('Memory ${sample.memoryPercent.toStringAsFixed(1)}%');
    }
    if (diskMax >= 85) details.add('Disk ${diskMax.toStringAsFixed(1)}%');
    final level =
        score < 45 ||
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

  void _trimSamples(String connectionId) {
    final now = _clock();
    final samples = _samples[connectionId];
    if (samples == null || samples.isEmpty) return;
    samples.removeWhere(
      (sample) => sample.time.isBefore(now.subtract(maxRetention)),
    );
    final downsampleCutoff = now.subtract(const Duration(minutes: 5));
    final older = <PerformanceSample>[];
    final newer = <PerformanceSample>[];
    for (final sample in samples) {
      (sample.time.isBefore(downsampleCutoff) ? older : newer).add(sample);
    }
    if (older.isEmpty) return;
    final compacted = <PerformanceSample>[];
    var bucket = <PerformanceSample>[];
    for (final sample in older) {
      if (bucket.isEmpty ||
          sample.time.difference(bucket.first.time) <
              const Duration(seconds: 10)) {
        bucket.add(sample);
      } else {
        compacted.add(_averageSamples(bucket));
        bucket = <PerformanceSample>[sample];
      }
    }
    if (bucket.isNotEmpty) compacted.add(_averageSamples(bucket));
    samples
      ..clear()
      ..addAll(compacted)
      ..addAll(newer);
  }

  PerformanceSample _averageSamples(List<PerformanceSample> samples) {
    if (samples.length == 1) return samples.first;
    final count = samples.length;
    return PerformanceSample(
      connectionId: samples.first.connectionId,
      time: DateTime.fromMillisecondsSinceEpoch(
        samples.fold<int>(
              0,
              (total, item) => total + item.time.millisecondsSinceEpoch,
            ) ~/
            count,
      ),
      cpuPercent:
          samples.fold<double>(0, (total, item) => total + item.cpuPercent) /
          count,
      memoryPercent:
          samples.fold<double>(0, (total, item) => total + item.memoryPercent) /
          count,
      diskBytesPerSecond:
          samples.fold<double>(
            0,
            (total, item) => total + item.diskBytesPerSecond,
          ) /
          count,
      networkBytesPerSecond:
          samples.fold<double>(
            0,
            (total, item) => total + item.networkBytesPerSecond,
          ) /
          count,
      diskUsage: samples[count ~/ 2].diskUsage,
    );
  }

  double _ratePercent(int totalDelta, int busyDelta) {
    if (totalDelta <= 0 || busyDelta <= 0) return 0;
    return busyDelta / totalDelta * 100;
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

  void _invalidateHealth() {
    _healthView = null;
    _healthEntries.clear();
  }

  void _invalidateHealthFor(String connectionId) {
    _healthView = null;
    _healthEntries.remove(connectionId);
  }

  void _invalidateVisible() {
    _visibleSamples.clear();
    _visibleCutoff = null;
    _visibleCutoffBucket = null;
    _visibleWindow = null;
  }
}
