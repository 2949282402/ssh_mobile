// 业务遥测生产者测试的共享夹具。
//
// 使用 MemoryTelemetryStorage + TelemetryClient 的默认 Policy，让生产者在
// 单元测试中真实走一遍 catalog 校验与插入链路；断言通过 [replayRecords]
// 读取落库记录。

import 'package:app_core/app_core.dart';

/// 内存遥测测试抽屉：持有客户端与存储两者引用，便于断言落库内容。
class TelemetryTestHarness {
  TelemetryTestHarness() : storage = MemoryTelemetryStorage() {
    client = TelemetryClient(
      config: const TelemetryClientConfig(
        baseUrl: 'https://relay.test',
        deviceId: 'test-device',
        appVersion: '1.0.0',
        buildNumber: '1',
        platform: 'linux',
        releaseChannel: 'test',
        telemetryEnabled: true,
      ),
      storage: storage,
    );
  }

  final MemoryTelemetryStorage storage;
  late final TelemetryClient client;

  /// 返回全部已落库记录（未做任何复制，按插入顺序）。
  Future<List<TelemetryEventRecord>> replayRecords() {
    return storage.fetchAllForReplay();
  }

  /// 返回事件名 -> 记录列表的分组映射。
  Future<Map<String, List<TelemetryEventRecord>>> recordsByName() async {
    final records = await replayRecords();
    final grouped = <String, List<TelemetryEventRecord>>{};
    for (final record in records) {
      grouped.putIfAbsent(record.eventName, () => []).add(record);
    }
    return grouped;
  }

  Future<void> dispose() => client.dispose();
}
