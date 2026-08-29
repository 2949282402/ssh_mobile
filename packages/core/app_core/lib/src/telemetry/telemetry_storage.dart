import 'telemetry_model.dart';
import 'telemetry_policy.dart';

/// 单条记录的上传确认结果。
///
/// [status] 为服务端返回的 `accepted`、`already_seen` 或 `rejected`；
/// `accepted` 与 `already_seen` 都表示记录已经被服务端幂等收据记录，
/// 客户端应当推进到 `synced + logicalDeletedAt = now`。
class TelemetryAckResult {
  const TelemetryAckResult({
    required this.eventId,
    required this.status,
    this.reason,
  });

  final String eventId;
  final String status; // accepted | already_seen | rejected
  final String? reason;

  bool get isAcceptedOrSeen => status == 'accepted' || status == 'already_seen';
  bool get isRejected => status == 'rejected';

  factory TelemetryAckResult.fromJson(Map<String, dynamic> json) {
    return TelemetryAckResult(
      eventId: json['eventId'] as String,
      status: json['status'] as String? ?? 'rejected',
      reason: json['reason'] as String?,
    );
  }
}

/// 本地存储健康快照。
class TelemetryStorageHealth {
  const TelemetryStorageHealth({
    required this.localPendingCount,
    required this.localRejectedCount,
    required this.localSyncedCount,
    required this.totalCount,
    required this.cacheOverflow,
  });

  final int localPendingCount;
  final int localRejectedCount;
  final int localSyncedCount;
  final int totalCount;
  final bool cacheOverflow;
}

/// Durable owner for the last policy accepted by the telemetry client.
///
/// Policy state is kept beside telemetry records by the production storage
/// implementation. The separate capability keeps existing test and migration
/// implementations source-compatible while allowing the client to require
/// this capability on its production path.
abstract interface class TelemetryPolicyStorage {
  Future<TelemetryUploadPolicy?> loadLastKnownGoodPolicy();
  Future<void> saveLastKnownGoodPolicy(TelemetryUploadPolicy policy);
}

/// Compatibility bridge for storage implementations that predate policy
/// persistence. Production storage implements [TelemetryPolicyStorage].
extension TelemetryPolicyStorageOperations on TelemetryStorage {
  Future<TelemetryUploadPolicy?> loadLastKnownGoodPolicy() async {
    if (this is TelemetryPolicyStorage) {
      return (this as TelemetryPolicyStorage).loadLastKnownGoodPolicy();
    }
    return null;
  }

  Future<void> saveLastKnownGoodPolicy(TelemetryUploadPolicy policy) async {
    if (this is TelemetryPolicyStorage) {
      await (this as TelemetryPolicyStorage).saveLastKnownGoodPolicy(policy);
    }
  }
}

/// 客户端遥测记录的本地持久化契约。
///
/// 生产实现必须保证：
/// - 任何写/插入/更新失败都必须抛出，绝不静默吞掉（调用方依赖异常做重试决策）。
/// - `purgeOldSyncedRecords` 只允许物理删除 `synced + logicalDeletedAt != null`
///   的记录；`pending` 与 `rejected` 记录永不因 FIFO 淘汰而物理删除。
abstract class TelemetryStorage {
  Future<void> insertRecord(TelemetryEventRecord record);
  Future<List<TelemetryEventRecord>> fetchPendingBatch(int limit);
  Future<void> applyAckResults(List<TelemetryAckResult> results);
  Future<void> applyRetryCount(List<String> eventIds, {required int increment});
  Future<List<TelemetryEventRecord>> fetchAllForReplay();
  Future<int> purgeOldSyncedRecords({required int targetCapacity});
  Future<TelemetryStorageHealth> getHealthStats({required int targetCapacity});
  TelemetryStorageHealth? get cachedHealthStats => null;
  Future<void> clearAll();
  Future<void> close();
}

/// 纯内存测试替身。
///
/// 仅用于单元测试；生产路径必须使用 SQLite/Drift 实现，绝不使用内存或
/// JSONL 存储。
class MemoryTelemetryStorage
    implements TelemetryStorage, TelemetryPolicyStorage {
  final List<TelemetryEventRecord> _records = [];
  TelemetryUploadPolicy? _lastKnownGoodPolicy;

  @override
  Future<TelemetryUploadPolicy?> loadLastKnownGoodPolicy() async {
    return _lastKnownGoodPolicy;
  }

  @override
  Future<void> saveLastKnownGoodPolicy(TelemetryUploadPolicy policy) async {
    _lastKnownGoodPolicy = policy;
  }

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    _records.add(record);
  }

  @override
  Future<List<TelemetryEventRecord>> fetchPendingBatch(int limit) async {
    return _records
        .where((r) => r.syncState == TelemetrySyncState.pending)
        .take(limit > 0 ? limit : 50)
        .toList();
  }

  @override
  Future<void> applyAckResults(List<TelemetryAckResult> results) async {
    final now = DateTime.now().toUtc();
    final resultMap = {for (final res in results) res.eventId: res};

    for (var i = 0; i < _records.length; i++) {
      final rec = _records[i];
      final ack = resultMap[rec.eventId];
      if (ack == null) continue;

      if (ack.isAcceptedOrSeen) {
        _records[i] = rec.copyWith(
          syncState: TelemetrySyncState.synced,
          logicalDeletedAt: now,
          retryCount: 0,
        );
      } else if (ack.isRejected) {
        _records[i] = rec.copyWith(
          syncState: TelemetrySyncState.rejected,
          clearLogicalDeletedAt: true,
        );
      }
    }
  }

  @override
  Future<void> applyRetryCount(
    List<String> eventIds, {
    required int increment,
  }) async {
    final idSet = eventIds.toSet();
    for (var i = 0; i < _records.length; i++) {
      if (!idSet.contains(_records[i].eventId)) continue;
      final rec = _records[i];
      _records[i] = rec.copyWith(retryCount: rec.retryCount + increment);
    }
  }

  @override
  Future<List<TelemetryEventRecord>> fetchAllForReplay() async {
    return List.unmodifiable(_records);
  }

  @override
  Future<int> purgeOldSyncedRecords({required int targetCapacity}) async {
    if (targetCapacity <= 0) return 0;
    final total = _records.length;
    if (total <= targetCapacity) return 0;

    // 只允许淘汰 synced + logicalDeletedAt != null 的记录。
    final syncedRecords =
        _records
            .where(
              (r) =>
                  r.syncState == TelemetrySyncState.synced &&
                  r.logicalDeletedAt != null,
            )
            .toList()
          ..sort(
            (a, b) => (a.logicalDeletedAt ?? a.occurredAt).compareTo(
              b.logicalDeletedAt ?? b.occurredAt,
            ),
          );

    final excess = total - targetCapacity;
    final toDeleteCount = excess < syncedRecords.length
        ? excess
        : syncedRecords.length;
    if (toDeleteCount <= 0) return 0;

    final deleteIds = syncedRecords
        .take(toDeleteCount)
        .map((r) => r.eventId)
        .toSet();
    _records.removeWhere((r) => deleteIds.contains(r.eventId));

    return toDeleteCount;
  }

  /// 同步统计健康快照，供 Developer 面板的同步读取路径使用。
  TelemetryStorageHealth getHealthStatsSync({required int targetCapacity}) {
    var pending = 0;
    var rejected = 0;
    var synced = 0;

    for (final r in _records) {
      switch (r.syncState) {
        case TelemetrySyncState.new_:
        case TelemetrySyncState.pending:
          pending++;
          break;
        case TelemetrySyncState.rejected:
          rejected++;
          break;
        case TelemetrySyncState.synced:
          synced++;
          break;
      }
    }

    final total = _records.length;
    final overflow = total > targetCapacity;

    return TelemetryStorageHealth(
      localPendingCount: pending,
      localRejectedCount: rejected,
      localSyncedCount: synced,
      totalCount: total,
      cacheOverflow: overflow,
    );
  }

  @override
  TelemetryStorageHealth? get cachedHealthStats =>
      getHealthStatsSync(targetCapacity: 1000);

  @override
  Future<TelemetryStorageHealth> getHealthStats({
    required int targetCapacity,
  }) async {
    return getHealthStatsSync(targetCapacity: targetCapacity);
  }

  @override
  Future<void> clearAll() async {
    _records.clear();
  }

  @override
  Future<void> close() async {}
}
