part of '../../telemetry_database.dart';

/// 遥测记录表。
///
/// 保存完整 Envelope 字段 + 本地同步状态机字段。索引覆盖 eventId 唯一性
/// 与 (sync_state, created_at) 的批量拉取路径，避免上传分发器扫描全表。
// Drift replaces this declaration with a generated TableInfo subclass; the
// column builders below are declarative schema input rather than executable
// business logic.
// coverage:ignore-start
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_telemetry_records_event_id '
  'ON telemetry_records(event_id)',
)
@TableIndex(
  name: 'idx_telemetry_records_sync_created',
  columns: {#syncState, #createdAt},
)
class TelemetryRecords extends Table {
  /// 服务端幂等事件 ID。
  TextColumn get eventId => text()();

  /// 记录类型（analytics | diagnostic）。
  TextColumn get recordType => text()();

  /// 事件名称。
  TextColumn get eventName => text()();

  /// 事件版本。
  IntColumn get eventVersion => integer()();

  /// 设备 ID。
  TextColumn get deviceId => text()();

  /// 会话 ID。
  TextColumn get sessionId => text()();

  /// 追踪 ID。
  TextColumn get traceId => text()();

  /// 发生在时间（ISO-8601 UTC）。
  TextColumn get occurredAt => text()();

  /// 功能域。
  TextColumn get feature => text()();

  /// 严重级别（info | warn | error | critical）。
  TextColumn get severity => text()();

  /// 应用版本。
  TextColumn get appVersion => text()();

  /// 构建号。
  TextColumn get buildNumber => text()();

  /// 平台。
  TextColumn get platform => text()();

  /// 发布渠道；旧记录可能没有该字段。
  TextColumn get releaseChannel => text().nullable()();

  /// 序列化的属性 JSON。
  TextColumn get properties => text()();

  /// 序列化的错误详情 JSON；可空。
  TextColumn get error => text().nullable()();

  /// 同步状态（pending | synced | rejected）。
  TextColumn get syncState => text()();

  /// 逻辑删除时间（ISO-8601 UTC）；可空。
  TextColumn get logicalDeletedAt => text().nullable()();

  /// 重试次数。
  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  /// 本地写入时间，用于按时间淘汰和新旧排序。
  DateTimeColumn get createdAt => dateTime()();
}
// coverage:ignore-end
