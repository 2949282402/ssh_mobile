part of '../../telemetry_database.dart';

/// 遥测记录表的最小持久化访问面。
@DriftAccessor(tables: [TelemetryRecords])
class TelemetryRecordsDao extends DatabaseAccessor<TelemetryDatabase>
    with _$TelemetryRecordsDaoMixin {
  TelemetryRecordsDao(super.db);

  /// 插入一条记录；eventId 冲突时抛出唯一约束异常。
  Future<int> insertRecord(TelemetryRecordsCompanion record) {
    return into(telemetryRecords).insert(record);
  }

  /// 按同步状态从旧到新读取 pending 批次。
  Future<List<TelemetryRecord>> fetchPendingBatch(int limit) {
    return (select(telemetryRecords)
          ..where((t) => t.syncState.equals(TelemetrySyncStateWire.pending))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
            (t) => OrderingTerm(expression: t.eventId, mode: OrderingMode.asc),
          ])
          ..limit(limit))
        .get();
  }

  /// 读取全部记录，供开发者面板原样重放使用。
  Future<List<TelemetryRecord>> fetchAll() {
    return (select(telemetryRecords)..orderBy([
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
          (t) => OrderingTerm(expression: t.eventId, mode: OrderingMode.asc),
        ]))
        .get();
  }

  /// 递增指定 eventId 的重试次数。
  ///
  /// 使用参数化的 `UPDATE` 确保不会把用户数据拼进 SQL。
  Future<void> incrementRetryCount(Set<String> eventIds) async {
    if (eventIds.isEmpty) return;
    final placeholders = List.filled(eventIds.length, '?').join(', ');
    await customStatement(
      'UPDATE telemetry_records SET retry_count = retry_count + 1 '
      'WHERE event_id IN ($placeholders)',
      [for (final id in eventIds) id],
    );
  }

  /// 统计各状态数量与总数。
  Future<({int pending, int rejected, int synced, int total})>
  countStates() async {
    final pending = await _countWhere(
      (t) => t.syncState.equals(TelemetrySyncStateWire.pending),
    );
    final rejected = await _countWhere(
      (t) => t.syncState.equals(TelemetrySyncStateWire.rejected),
    );
    final synced = await _countWhere(
      (t) => t.syncState.equals(TelemetrySyncStateWire.synced),
    );
    final total = await _countAll();
    return (pending: pending, rejected: rejected, synced: synced, total: total);
  }

  Future<int> _countWhere(
    Expression<bool> Function(TelemetryRecords table) predicate,
  ) {
    final countExpr = countAll();
    final query = selectOnly(telemetryRecords)
      ..addColumns([countExpr])
      ..where(predicate(telemetryRecords));
    return query.getSingle().then((row) => row.read(countExpr) ?? 0);
  }

  Future<int> _countAll() {
    final countExpr = countAll();
    final query = selectOnly(telemetryRecords)..addColumns([countExpr]);
    return query.getSingle().then((row) => row.read(countExpr) ?? 0);
  }

  /// 清空全部记录。
  Future<void> clearAll() {
    return delete(telemetryRecords).go();
  }
}

/// 遥控同步状态的存储 wire 值。
abstract final class TelemetrySyncStateWire {
  static const String pending = 'pending';
  static const String synced = 'synced';
  static const String rejected = 'rejected';
}
