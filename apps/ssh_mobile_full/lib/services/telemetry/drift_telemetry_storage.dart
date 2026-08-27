// Drift/SQLite 支撑的遥测本地持久化实现。
//
// 作为生产路径的 [TelemetryStorage]，替代旧的内存/JSONL 存储。任何写入
// 失败都会向上抛出，绝不静默吞掉。

import 'dart:convert';
import 'dart:math' as math;

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'telemetry_database.dart';

/// SQLite（Drift）支撑的遥测存储实现。
class DriftTelemetryStorage implements TelemetryStorage {
  DriftTelemetryStorage({TelemetryDatabase? database})
    : _database = database ?? TelemetryDatabase();

  final TelemetryDatabase _database;
  bool _closed = false;

  /// 数据库控制器，供移植测试注入。
  @visibleForTesting
  TelemetryDatabase get database => _database;

  @visibleForTesting
  bool get isClosed => _closed;

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    if (_closed) {
      throw StateError('Telemetry storage already closed');
    }
    final recordRow = _toCompanion(record);
    await _database.into(_database.telemetryRecords).insert(
      recordRow,
      onConflict: DoNothing(
        target: [_database.telemetryRecords.eventId],
      ),
    );
  }

  @override
  Future<List<TelemetryEventRecord>> fetchPendingBatch(int limit) async {
    if (_closed) {
      throw StateError('Telemetry storage already closed');
    }
    final rows = await _database.telemetryRecordsDao.fetchPendingBatch(
      limit > 0 ? limit : 50,
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<void> applyAckResults(List<TelemetryAckResult> results) async {
    if (_closed) {
      throw StateError('Telemetry storage already closed');
    }
    if (results.isEmpty) return;
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      for (final ack in results) {
        final row = await (_database.select(_database.telemetryRecords)
              ..where((t) => t.eventId.equals(ack.eventId)))
            .getSingleOrNull();
        if (row == null) continue;
        if (ack.isAcceptedOrSeen) {
          await (_database.update(_database.telemetryRecords)
                ..where((t) => t.eventId.equals(ack.eventId)))
              .write(
                TelemetryRecordsCompanion(
                  syncState: Value(TelemetrySyncState.synced.wireValue),
                  logicalDeletedAt: Value(now.toIso8601String()),
                  retryCount: const Value(0),
                ),
              );
        } else if (ack.isRejected) {
          await (_database.update(_database.telemetryRecords)
                ..where((t) => t.eventId.equals(ack.eventId)))
              .write(
                TelemetryRecordsCompanion(
                  syncState: Value(TelemetrySyncState.rejected.wireValue),
                  logicalDeletedAt: const Value(null),
                ),
              );
        }
      }
    });
  }

  @override
  Future<void> applyRetryCount(
    List<String> eventIds, {
    required int increment,
  }) async {
    if (_closed) {
      throw StateError('Telemetry storage already closed');
    }
    if (eventIds.isEmpty) return;
    if (increment == 0) return;
    final idBatches = _chunked(eventIds, 200);
    await _database.transaction(() async {
      for (final batch in idBatches) {
        await _database.telemetryRecordsDao.incrementRetryCount(batch.toSet());
      }
    });
  }

  @override
  Future<List<TelemetryEventRecord>> fetchAllForReplay() async {
    if (_closed) {
      throw StateError('Telemetry storage already closed');
    }
    final rows = await _database.telemetryRecordsDao.fetchAll();
    return rows.map(_fromRow).toList();
  }

  @override
  Future<int> purgeOldSyncedRecords({required int targetCapacity}) async {
    if (_closed) {
      throw StateError('Telemetry storage already closed');
    }
    if (targetCapacity <= 0) return 0;

    return _database.transaction(() async {
      final total = await _database.telemetryRecordsDao.countStates();
      if (total.total <= targetCapacity) return 0;

      // 找出所有 synced + logicalDeletedAt != null 的记录（按淘汰时间最旧优先）。
      final rows = await (_database.select(_database.telemetryRecords)
            ..where(
              (t) =>
                  t.syncState.equals(TelemetrySyncState.synced.wireValue) &
                  t.logicalDeletedAt.isNotNull(),
            )
            ..orderBy([
              (t) => OrderingTerm(expression: t.createdAt,
                  mode: OrderingMode.asc),
              (t) => OrderingTerm(expression: t.eventId,
                  mode: OrderingMode.asc),
            ]))
          .get();

      if (rows.isEmpty) return 0;

      final excess = total.total - targetCapacity;
      final toDelete = excess < rows.length ? excess : rows.length;
      final deleteIds = rows.take(toDelete).map((r) => r.eventId).toSet();

      await (_database.delete(_database.telemetryRecords)
            ..where((t) => t.eventId.isIn(deleteIds)))
          .go();
      return toDelete;
    });
  }

  TelemetryStorageHealth? _lastHealthSnapshot;

  @override
  TelemetryStorageHealth? get cachedHealthStats => _lastHealthSnapshot;

  @override
  Future<TelemetryStorageHealth> getHealthStats({
    required int targetCapacity,
  }) async {
    if (_closed) {
      throw StateError('Telemetry storage already closed');
    }
    final counts = await _database.telemetryRecordsDao.countStates();
    final health = TelemetryStorageHealth(
      localPendingCount: counts.pending,
      localRejectedCount: counts.rejected,
      localSyncedCount: counts.synced,
      totalCount: counts.total,
      cacheOverflow: counts.total > targetCapacity,
    );
    _lastHealthSnapshot = health;
    return health;
  }

  @override
  Future<void> clearAll() async {
    if (_closed) return;
    await _database.telemetryRecordsDao.clearAll();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.dispose();
  }

  static List<List<T>> _chunked<T>(List<T> list, int size) {
    if (size <= 0) return [list];
    final chunks = <List<T>>[];
    for (var i = 0; i < list.length; i += size) {
      chunks.add(list.sublist(i, math.min(i + size, list.length)));
    }
    return chunks;
  }

  TelemetryRecordsCompanion _toCompanion(TelemetryEventRecord record) {
    return TelemetryRecordsCompanion(
      eventId: Value(record.eventId),
      recordType: Value(record.recordType.wireValue),
      eventName: Value(record.eventName),
      eventVersion: Value(record.eventVersion),
      deviceId: Value(record.deviceId),
      sessionId: Value(record.sessionId),
      traceId: Value(record.traceId),
      occurredAt: Value(record.occurredAt.toUtc().toIso8601String()),
      feature: Value(record.feature),
      severity: Value(record.severity.wireValue),
      appVersion: Value(record.appVersion),
      buildNumber: Value(record.buildNumber),
      platform: Value(record.platform),
      properties: Value(jsonEncode(record.properties)),
      error: Value(record.error != null ? jsonEncode(record.error!.toJson()) : null),
      syncState: Value(_syncStateToWire(record.syncState)),
      logicalDeletedAt: Value(
        record.logicalDeletedAt?.toUtc().toIso8601String(),
      ),
      retryCount: Value(record.retryCount),
      createdAt: Value(record.occurredAt.toUtc()),
    );
  }

  TelemetryEventRecord _fromRow(TelemetryRecord row) {
    return TelemetryEventRecord(
      eventId: row.eventId,
      recordType: TelemetryRecordType.fromWireValue(row.recordType),
      eventName: row.eventName,
      eventVersion: row.eventVersion,
      deviceId: row.deviceId,
      sessionId: row.sessionId,
      traceId: row.traceId,
      occurredAt: DateTime.parse(row.occurredAt),
      feature: row.feature,
      severity: TelemetrySeverity.fromWireValue(row.severity),
      appVersion: row.appVersion,
      buildNumber: row.buildNumber,
      platform: row.platform,
      properties:
          (jsonDecode(row.properties) as Map<String, dynamic>?) ?? const {},
      error: row.error != null
          ? TelemetryErrorDetail.fromJson(
              jsonDecode(row.error!) as Map<String, dynamic>,
            )
          : null,
      syncState: _syncStateFromWire(row.syncState),
      logicalDeletedAt: row.logicalDeletedAt != null
          ? DateTime.parse(row.logicalDeletedAt!)
          : null,
      retryCount: row.retryCount,
    );
  }

  static TelemetrySyncState _syncStateFromWire(String value) {
    switch (value) {
      case 'new':
        return TelemetrySyncState.new_;
      case 'synced':
        return TelemetrySyncState.synced;
      case 'rejected':
        return TelemetrySyncState.rejected;
      default:
        return TelemetrySyncState.pending;
    }
  }

  static String _syncStateToWire(TelemetrySyncState state) {
    switch (state) {
      case TelemetrySyncState.new_:
        return 'new';
      case TelemetrySyncState.pending:
        return 'pending';
      case TelemetrySyncState.synced:
        return 'synced';
      case TelemetrySyncState.rejected:
        return 'rejected';
    }
  }
}