// App Scope 业务遥测 span 辅助工具。
//
// TelemetryClient 的 traceId 不传递时会自动生成 UUID v4；为了让同一个业务
// 操作的多个事件（started -> connected -> terminated/failed）共享同一个
// traceId，生产者在这里显式生成并沿 span 传递。格式与 app_core 内部一致，
// 保证 App Runtime 生产路径与单元测试路径都能被后端按 traceId 关联。

import 'package:uuid/uuid.dart';

const Uuid _spanUuid = Uuid();

/// 生成一个与 TelemetryClient 默认格式一致的 traceId。
String newTelemetryTraceId() => _spanUuid.v4();

/// 计算 span 耗时（毫秒）。开始时间缺失时返回 0，避免泄漏无意义的负值。
int telemetryElapsedMs(DateTime? startedAt) {
  if (startedAt == null) return 0;
  return DateTime.now().difference(startedAt).inMilliseconds;
}