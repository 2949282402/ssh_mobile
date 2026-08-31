// 业务遥测生产者测试的共享夹具。
//
// 使用 MemoryTelemetryStorage + TelemetryClient 的默认 Policy，让生产者在
// 单元测试中真实走一遍 catalog 校验与插入链路；断言通过 [replayRecords]
// 读取落库记录。

import 'package:app_core/app_core.dart';

/// 内存遥测测试抽屉：持有客户端与存储两者引用，便于断言落库内容。
class TelemetryTestHarness {
  TelemetryTestHarness() : storage = MemoryTelemetryStorage() {
    _trackingClient = _TrackingTelemetryClient(
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
    client = _trackingClient;
  }

  final MemoryTelemetryStorage storage;
  late final TelemetryClient client;
  late final _TrackingTelemetryClient _trackingClient;

  /// 返回全部已落库记录（未做任何复制，按插入顺序）。
  Future<List<TelemetryEventRecord>> replayRecords() {
    return storage.fetchAllForReplay();
  }

  /// 返回事件名 -> 记录列表的分组映射。
  Future<Map<String, List<TelemetryEventRecord>>> recordsByName() async {
    await _trackingClient.drainRecords();
    final records = await replayRecords();
    final grouped = <String, List<TelemetryEventRecord>>{};
    for (final record in records) {
      grouped.putIfAbsent(record.eventName, () => []).add(record);
    }
    return grouped;
  }

  Future<void> dispose() => client.dispose();
}

/// Tracks fire-and-forget producer writes so assertions observe their durable
/// result without adding a production-only drain hook to [TelemetryClient].
final class _TrackingTelemetryClient extends TelemetryClient {
  _TrackingTelemetryClient({required super.config, required super.storage});

  Future<void> _pendingRecords = Future<void>.value();

  @override
  Future<bool> record({
    required TelemetryEventDefinition event,
    Map<String, dynamic> properties = const {},
    TelemetryErrorCodeDefinition? errorCode,
    String? errorMessage,
    String? stackTrace,
    String? sessionId,
    String? traceId,
  }) {
    final result = super.record(
      event: event,
      properties: properties,
      errorCode: errorCode,
      errorMessage: errorMessage,
      stackTrace: stackTrace,
      sessionId: sessionId,
      traceId: traceId,
    );
    _pendingRecords = _pendingRecords
        .then<void>((_) => result)
        .catchError((_) {});
    return result;
  }

  Future<void> drainRecords() => _pendingRecords;
}
