import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'telemetry_model.dart';

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

abstract class TelemetryStorage {
  Future<void> insertRecord(TelemetryEventRecord record);
  Future<List<TelemetryEventRecord>> fetchPendingBatch(int limit);
  Future<void> applyAckResults(List<TelemetryAckResult> results);
  Future<List<TelemetryEventRecord>> fetchAllForReplay();
  Future<int> purgeOldSyncedRecords({required int targetCapacity});
  Future<TelemetryStorageHealth> getHealthStats({required int targetCapacity});
  Future<void> clearAll();
  Future<void> close();
}

class MemoryTelemetryStorage implements TelemetryStorage {
  final List<TelemetryEventRecord> _records = [];

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
  Future<List<TelemetryEventRecord>> fetchAllForReplay() async {
    return List.unmodifiable(_records);
  }

  @override
  Future<int> purgeOldSyncedRecords({required int targetCapacity}) async {
    if (targetCapacity <= 0) return 0;
    final total = _records.length;
    if (total <= targetCapacity) return 0;

    // Collect all synced records sorted by occurredAt / logicalDeletedAt ascending (oldest first)
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

  TelemetryStorageHealth getHealthStatsSync({required int targetCapacity}) {
    var pending = 0;
    var rejected = 0;
    var synced = 0;

    for (final r in _records) {
      switch (r.syncState) {
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

class _AsyncLock {
  Future<void> _last = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _last = _last.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}

class FileTelemetryStorage implements TelemetryStorage {
  FileTelemetryStorage({required this.filePath}) {
    _memory = MemoryTelemetryStorage();
  }

  final String filePath;
  late final MemoryTelemetryStorage _memory;
  MemoryTelemetryStorage get memory => _memory;
  final _AsyncLock _lock = _AsyncLock();
  bool _loaded = false;

  TelemetryStorageHealth getHealthStatsSync({required int targetCapacity}) {
    if (!_loaded) {
      _ensureLoadedSync();
    }
    return _memory.getHealthStatsSync(targetCapacity: targetCapacity);
  }

  void _ensureLoadedSync() {
    if (_loaded) return;
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        final lines = file.readAsLinesSync();
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final jsonMap = jsonDecode(line) as Map<String, dynamic>;
            final rec = TelemetryEventRecord.fromJson(jsonMap).copyWith(
              syncState: TelemetrySyncState.fromWireValue(
                jsonMap['syncState'] as String? ?? 'pending',
              ),
              logicalDeletedAt: jsonMap['logicalDeletedAt'] != null
                  ? DateTime.parse(jsonMap['logicalDeletedAt'] as String)
                  : null,
              retryCount: jsonMap['retryCount'] as int? ?? 0,
            );
            _memory.insertRecord(rec);
          } catch (_) {
            // Ignore malformed line
          }
        }
      }
      _loaded = true;
    } catch (_) {}
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final lines = await file.readAsLines();
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final jsonMap = jsonDecode(line) as Map<String, dynamic>;
            final rec = TelemetryEventRecord.fromJson(jsonMap).copyWith(
              syncState: TelemetrySyncState.fromWireValue(
                jsonMap['syncState'] as String? ?? 'pending',
              ),
              logicalDeletedAt: jsonMap['logicalDeletedAt'] != null
                  ? DateTime.parse(jsonMap['logicalDeletedAt'] as String)
                  : null,
              retryCount: jsonMap['retryCount'] as int? ?? 0,
            );
            await _memory.insertRecord(rec);
          } catch (_) {
            // Ignore malformed line
          }
        }
      }
      _loaded = true;
    } catch (_) {}
  }

  Future<void> _persistToDisk() async {
    if (!_loaded) return;
    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      final records = await _memory.fetchAllForReplay();
      final sink = file.openWrite(mode: FileMode.writeOnly);
      for (final r in records) {
        final map = r.toJson();
        map['syncState'] = r.syncState.wireValue;
        if (r.logicalDeletedAt != null) {
          map['logicalDeletedAt'] = r.logicalDeletedAt!
              .toUtc()
              .toIso8601String();
        }
        map['retryCount'] = r.retryCount;
        sink.writeln(jsonEncode(map));
      }
      await sink.flush();
      await sink.close();
    } catch (_) {}
  }

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    return _lock.synchronized(() async {
      await _ensureLoaded();
      await _memory.insertRecord(record);
      try {
        final file = File(filePath);
        await file.parent.create(recursive: true);
        final map = record.toJson();
        map['syncState'] = record.syncState.wireValue;
        if (record.logicalDeletedAt != null) {
          map['logicalDeletedAt'] = record.logicalDeletedAt!
              .toUtc()
              .toIso8601String();
        }
        map['retryCount'] = record.retryCount;
        final sink = file.openWrite(mode: FileMode.append);
        sink.writeln(jsonEncode(map));
        await sink.flush();
        await sink.close();
      } catch (_) {}
    });
  }

  @override
  Future<List<TelemetryEventRecord>> fetchPendingBatch(int limit) async {
    return _lock.synchronized(() async {
      await _ensureLoaded();
      return _memory.fetchPendingBatch(limit);
    });
  }

  @override
  Future<void> applyAckResults(List<TelemetryAckResult> results) async {
    return _lock.synchronized(() async {
      await _ensureLoaded();
      await _memory.applyAckResults(results);
      await _persistToDisk();
    });
  }

  @override
  Future<List<TelemetryEventRecord>> fetchAllForReplay() async {
    return _lock.synchronized(() async {
      await _ensureLoaded();
      return _memory.fetchAllForReplay();
    });
  }

  @override
  Future<int> purgeOldSyncedRecords({required int targetCapacity}) async {
    return _lock.synchronized(() async {
      await _ensureLoaded();
      final count = await _memory.purgeOldSyncedRecords(
        targetCapacity: targetCapacity,
      );
      if (count > 0) {
        await _persistToDisk();
      }
      return count;
    });
  }

  @override
  Future<TelemetryStorageHealth> getHealthStats({
    required int targetCapacity,
  }) async {
    return _lock.synchronized(() async {
      await _ensureLoaded();
      return _memory.getHealthStats(targetCapacity: targetCapacity);
    });
  }

  @override
  Future<void> clearAll() async {
    return _lock.synchronized(() async {
      await _ensureLoaded();
      await _memory.clearAll();
      await _persistToDisk();
    });
  }

  @override
  Future<void> close() async {
    return _lock.synchronized(() async {
      await _memory.close();
    });
  }
}
