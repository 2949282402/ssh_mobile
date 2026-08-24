// 监控采样内存 Owner 的独立测试。

import 'package:feature_monitoring/src/application/monitoring_sample_store.dart';
import 'package:feature_monitoring/src/domain/monitoring_models.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 23, 12);

  test('empty and failed connections expose immutable health views', () {
    final store = _store(now);
    store.resetForMonitoring(const <String>['a', 'b']);

    expect(store.healthFor('a').level, ServerHealthLevel.unknown);
    final firstMap = store.healthForConnections(const <String>['a', 'b']);
    expect(firstMap.keys, containsAll(<String>['a', 'b']));
    expect(() => firstMap['c'] = store.healthFor('c'), throwsUnsupportedError);

    store.recordError('a', 'offline');
    expect(store.errors['a'], 'offline');
    expect(() => store.errors['b'] = 'x', throwsUnsupportedError);
    final failed = store.healthFor('a');
    expect(failed.level, ServerHealthLevel.critical);
    expect(failed.summary, 'Sampling failed');
    expect(failed.details, <String>['offline']);

    store.stopMonitoring();
    expect(store.errors, isEmpty);
    expect(store.healthFor('a').level, ServerHealthLevel.unknown);
    store.removeConnection('a');
    store.invalidateConnectionSet();
    expect(store.healthForConnections(const <String>['b']).keys, <String>['b']);
  });

  test('records immutable samples and computes all health levels', () {
    final store = _store(now);
    store.resetForMonitoring(const <String>['healthy', 'warning', 'critical']);
    final disk = <DiskUsageSnapshot>[_disk(86)];

    store.recordSample(
      'healthy',
      _sample('healthy', now, cpu: 20, memory: 30),
      const [],
    );
    store.recordSample(
      'warning',
      _sample('warning', now, cpu: 86, memory: 50, disks: disk),
      disk,
    );
    store.recordSample(
      'critical',
      _sample(
        'critical',
        now,
        cpu: 96,
        memory: 96,
        disks: <DiskUsageSnapshot>[_disk(96)],
      ),
      <DiskUsageSnapshot>[_disk(96)],
    );

    expect(store.healthFor('healthy').level, ServerHealthLevel.healthy);
    final warning = store.healthFor('warning');
    expect(warning.level, ServerHealthLevel.warning);
    expect(warning.details, containsAll(<String>['CPU 86.0%', 'Disk 86.0%']));
    expect(warning.maxDiskUsedPercent, 86);
    expect(store.healthFor('critical').level, ServerHealthLevel.critical);
    expect(store.healthFor('critical').score, lessThan(45));
    expect(store.samplesFor('warning'), hasLength(1));
    expect(store.diskUsageFor('warning'), disk);
    expect(
      () => store.samplesFor('warning').add(_sample('warning', now)),
      throwsUnsupportedError,
    );
    expect(() => store.diskUsageFor('warning').clear(), throwsUnsupportedError);
  });

  test('counter conversion uses prior accepted counters and clamps rates', () {
    final store = _store(now);
    store.resetForMonitoring(const <String>['a']);
    final firstCounters = RawPerformanceCounters(
      time: now.subtract(const Duration(seconds: 10)),
      cpuTotal: 100,
      cpuBusy: 50,
      memoryPercent: 120,
      diskBytes: 1000,
      networkBytes: 2000,
    );
    final first = store.sampleFromCounters(
      'a',
      firstCounters,
      firstCounters.time,
      const <DiskUsageSnapshot>[],
      const Duration(seconds: 10),
    );
    expect(first.cpuPercent, 0);
    expect(first.memoryPercent, 100);
    expect(first.diskBytesPerSecond, 0);
    store.recordError('a', 'old');
    expect(
      store.recordSample('a', first, const [], counters: firstCounters),
      isTrue,
    );

    final secondCounters = RawPerformanceCounters(
      time: now,
      cpuTotal: 300,
      cpuBusy: 150,
      memoryPercent: -5,
      diskBytes: 3000,
      networkBytes: 5000,
    );
    final second = store.sampleFromCounters(
      'a',
      secondCounters,
      now,
      const <DiskUsageSnapshot>[],
      const Duration(seconds: 10),
    );
    expect(second.cpuPercent, 50);
    expect(second.memoryPercent, 0);
    expect(second.diskBytesPerSecond, 200);
    expect(second.networkBytesPerSecond, 300);
    store.recordSample('a', second, const [], counters: secondCounters);

    final regressed = store.sampleFromCounters(
      'a',
      RawPerformanceCounters(
        time: now,
        cpuTotal: 200,
        cpuBusy: 100,
        memoryPercent: 10,
        diskBytes: 100,
        networkBytes: 100,
      ),
      now,
      const <DiskUsageSnapshot>[],
      const Duration(seconds: 10),
    );
    expect(regressed.cpuPercent, 0);
    expect(regressed.diskBytesPerSecond, 0);
    expect(regressed.networkBytesPerSecond, 0);
  });

  test('retention, compaction and visible window remain bounded', () {
    final store = _store(now);
    store.resetForMonitoring(const <String>['a']);
    store.recordSample(
      'a',
      _sample('a', now.subtract(const Duration(minutes: 11))),
      const [],
    );
    expect(store.samplesFor('a'), isEmpty);

    store.recordSample(
      'a',
      _sample('a', now.subtract(const Duration(minutes: 6)), cpu: 10),
      const [],
    );
    store.recordSample(
      'a',
      _sample(
        'a',
        now.subtract(const Duration(minutes: 5, seconds: 55)),
        cpu: 30,
      ),
      const [],
    );
    store.recordSample(
      'a',
      _sample(
        'a',
        now.subtract(const Duration(minutes: 5, seconds: 30)),
        cpu: 50,
      ),
      const [],
    );
    store.recordSample(
      'a',
      _sample('a', now.subtract(const Duration(seconds: 20)), cpu: 70),
      const [],
    );

    final samples = store.samplesFor('a');
    expect(samples, hasLength(3));
    expect(samples.first.cpuPercent, 20);
    expect(samples.last.cpuPercent, 70);
    expect(store.visibleSamplesFor('a'), hasLength(1));
    expect(
      identical(store.visibleSamplesFor('a'), store.visibleSamplesFor('a')),
      isTrue,
    );

    store.setHistoryWindow(const Duration(minutes: 10));
    expect(store.historyWindow, const Duration(minutes: 10));
    expect(store.visibleSamplesFor('a'), hasLength(3));
  });
}

MonitoringSampleStore _store(DateTime now) => MonitoringSampleStore(
  historyWindow: const Duration(minutes: 5),
  maxRetention: const Duration(minutes: 10),
  clock: () => now,
);

PerformanceSample _sample(
  String id,
  DateTime time, {
  double cpu = 10,
  double memory = 20,
  List<DiskUsageSnapshot> disks = const <DiskUsageSnapshot>[],
}) => PerformanceSample(
  connectionId: id,
  time: time,
  cpuPercent: cpu,
  memoryPercent: memory,
  diskBytesPerSecond: 1,
  networkBytesPerSecond: 2,
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
