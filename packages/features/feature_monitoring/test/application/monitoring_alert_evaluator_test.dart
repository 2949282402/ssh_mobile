// 监控告警判定 Owner 的独立测试。

import 'package:feature_monitoring/src/application/monitoring_alert_evaluator.dart';
import 'package:feature_monitoring/src/domain/monitoring_models.dart';
import 'package:test/test.dart';

void main() {
  test(
    'thresholds create typed alerts and suppress five-minute duplicates',
    () {
      var now = DateTime.utc(2026, 8, 23, 12);
      final evaluator = MonitoringAlertEvaluator(clock: () => now);
      evaluator.evaluate('a', _sample(cpu: 10, memory: 20), const []);
      expect(evaluator.alerts, isEmpty);

      final disk = <DiskUsageSnapshot>[_disk(96)];
      evaluator.evaluate('a', _sample(cpu: 86, memory: 95, disks: disk), disk);
      expect(evaluator.alerts, hasLength(3));
      expect(
        evaluator.alerts.map((alert) => alert.level),
        containsAll(<ServerHealthLevel>[
          ServerHealthLevel.warning,
          ServerHealthLevel.critical,
        ]),
      );
      expect(() => evaluator.alerts.clear(), throwsUnsupportedError);
      final stable = evaluator.alerts;

      evaluator.evaluate('a', _sample(cpu: 86, memory: 95, disks: disk), disk);
      expect(evaluator.alerts, hasLength(3));
      expect(identical(stable, evaluator.alerts), isTrue);

      now = now.add(const Duration(minutes: 5));
      evaluator.evaluate('a', _sample(cpu: 96, memory: 10), const []);
      expect(evaluator.alerts.first.metric, 'cpu');
      expect(evaluator.alerts.first.level, ServerHealthLevel.critical);
      evaluator.recordSamplingFailure('a', 'offline');
      expect(evaluator.alerts.first.message, contains('offline'));
    },
  );

  test('alert history is capped at eighty newest entries', () {
    var tick = 0;
    final base = DateTime.utc(2026, 8, 23);
    final evaluator = MonitoringAlertEvaluator(
      clock: () => base.add(Duration(microseconds: tick++)),
    );
    for (var index = 0; index < 90; index++) {
      evaluator.recordSamplingFailure('server-$index', 'failed');
    }

    expect(evaluator.alerts, hasLength(80));
    expect(evaluator.alerts.first.connectionId, 'server-89');
    expect(evaluator.alerts.last.connectionId, 'server-10');
  });
}

PerformanceSample _sample({
  required double cpu,
  required double memory,
  List<DiskUsageSnapshot> disks = const <DiskUsageSnapshot>[],
}) => PerformanceSample(
  connectionId: 'a',
  time: DateTime.utc(2026, 8, 23),
  cpuPercent: cpu,
  memoryPercent: memory,
  diskBytesPerSecond: 0,
  networkBytesPerSecond: 0,
  diskUsage: disks,
);

DiskUsageSnapshot _disk(double usedPercent) => DiskUsageSnapshot(
  filesystem: '/dev/test',
  mount: '/',
  totalBytes: 100,
  usedBytes: usedPercent.round(),
  availableBytes: 100 - usedPercent.round(),
  usedPercent: usedPercent,
);
