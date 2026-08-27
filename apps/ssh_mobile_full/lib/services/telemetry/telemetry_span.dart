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

/// App-owned operation context shared by SSH and the native network adapter.
///
/// A [TelemetryClient.sessionId] identifies the app process.  This registry
/// carries the traceId for one logical SSH connect operation across the
/// command protocol, which currently has no trace field of its own.  The
/// owner must call [dispose] after its borrowers (connector and telemetry
/// bridge) have released their subscriptions.
final class TelemetryTraceRegistry {
  TelemetryTraceRegistry({
    this.bindingTtl = const Duration(minutes: 5),
    this.maxBindings = 512,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (bindingTtl <= Duration.zero) {
      throw ArgumentError.value(
        bindingTtl,
        'bindingTtl',
        'must be greater than zero',
      );
    }
    if (maxBindings <= 0) {
      throw ArgumentError.value(maxBindings, 'maxBindings', 'must be positive');
    }
  }

  /// A stalled native operation must not retain a trace forever.
  final Duration bindingTtl;

  /// The registry is an adapter boundary, so its memory use is bounded even
  /// if a native peer never sends its terminal event.
  final int maxBindings;

  final DateTime Function() _clock;
  final Map<String, Map<String, DateTime>> _peerTraceIds =
      <String, Map<String, DateTime>>{};
  final Map<String, Map<String, _CommandTraceBinding>> _commandTraceIds =
      <String, Map<String, _CommandTraceBinding>>{};
  bool _disposed = false;

  /// Number of peer operation contexts currently retained by the owner.
  int get peerBindingCount => _peerTraceIds.values.fold<int>(
    0,
    (count, traces) => count + traces.length,
  );

  /// Number of command contexts currently retained by the owner.
  int get commandBindingCount => _commandTraceIds.values.fold<int>(
    0,
    (count, bindings) => count + bindings.length,
  );

  /// Whether the owner has crossed its terminal lifecycle boundary.
  bool get isDisposed => _disposed;

  /// Whether a peer currently has at least one operation context.
  bool hasPeerBinding(String peerId) {
    _prune();
    return _peerTraceIds[peerId]?.isNotEmpty == true;
  }

  /// Whether an active peer operation belongs to a different trace.
  bool hasPeerTraceOtherThan(String traceId) {
    _prune();
    return _peerTraceIds.values.any(
      (traces) => traces.keys.any((candidate) => candidate != traceId),
    );
  }

  /// Whether any active peer operation owns [traceId].
  bool hasTrace(String traceId) {
    _prune();
    return _peerTraceIds.values.any((traces) => traces.containsKey(traceId));
  }

  /// Associate a peer with the trace of its current SSH connect operation.
  void bindPeer({required String peerId, required String traceId}) {
    _ensureUsable();
    _prune();
    _validate(peerId, field: 'peerId');
    _validate(traceId, field: 'traceId');
    final traces = _peerTraceIds.putIfAbsent(
      peerId,
      () => <String, DateTime>{},
    );
    // A peer can have more than one in-flight SSH operation. We retain both
    // contexts and deliberately resolve peer-only events only when unambiguous
    // instead of attributing a late event to the most recent operation.
    traces[traceId] = _clock();
    _trimToCapacity();
  }

  /// Associate a native command with the same operation context as its peer.
  ///
  /// A command id collision retains both bindings and resolves the command as
  /// ambiguous, preventing a late result from being attributed to a newer
  /// operation.
  void bindCommand({
    required String commandId,
    required String peerId,
    required String traceId,
  }) {
    _ensureUsable();
    _prune();
    _validate(commandId, field: 'commandId');
    _validate(peerId, field: 'peerId');
    _validate(traceId, field: 'traceId');
    final bindings = _commandTraceIds.putIfAbsent(
      commandId,
      () => <String, _CommandTraceBinding>{},
    );
    bindings[_commandBindingKey(peerId, traceId)] = _CommandTraceBinding(
      peerId: peerId,
      traceId: traceId,
      touchedAt: _clock(),
    );
    _trimToCapacity();
  }

  /// Resolve a trace from a peer event without creating a new trace.
  String? traceForPeer(String peerId) {
    _prune();
    final traces = _peerTraceIds[peerId];
    if (traces == null || traces.length != 1) return null;
    final traceId = traces.keys.single;
    traces[traceId] = _clock();
    return traceId;
  }

  /// Resolve a trace from a native command result.
  String? traceForCommand(String commandId) {
    _prune();
    final bindings = _commandTraceIds[commandId];
    if (bindings == null || bindings.length != 1) return null;
    final binding = bindings.values.single;
    binding.touchedAt = _clock();
    return binding.traceId;
  }

  /// Resolve a relay-wide event only when it is unambiguous.
  ///
  /// Native Relay events currently do not carry a peer id.  Returning null
  /// when concurrent peer operations have different traces is safer than
  /// attributing one relay event to the wrong SSH operation.
  String? traceForAnyPeer() {
    _prune();
    final traces = <String>{};
    for (final peerTraces in _peerTraceIds.values) {
      traces.addAll(peerTraces.keys);
    }
    if (traces.length != 1) return null;
    final traceId = traces.single;
    final now = _clock();
    for (final peerTraces in _peerTraceIds.values) {
      if (peerTraces.containsKey(traceId)) peerTraces[traceId] = now;
    }
    return traceId;
  }

  /// Release a command result and, for rejected/expired commands, its peer.
  void completeCommand(
    String commandId, {
    bool retainPeerBinding = false,
    String? traceId,
  }) {
    _prune();
    final bindings = _commandTraceIds[commandId];
    if (bindings == null) return;

    final removed = <_CommandTraceBinding>[];
    if (traceId == null) {
      removed.addAll(bindings.values);
      _commandTraceIds.remove(commandId);
    } else {
      for (final entry in bindings.entries.toList(growable: false)) {
        if (entry.value.traceId != traceId) continue;
        removed.add(entry.value);
        bindings.remove(entry.key);
      }
      if (bindings.isEmpty) _commandTraceIds.remove(commandId);
    }

    // A command-id collision is intentionally ambiguous. Removing its
    // command entries is safe, but releasing a peer context here would risk
    // treating a late result for the old command as the newer operation.
    if (!retainPeerBinding && removed.length == 1) {
      final binding = removed.single;
      _releasePeerTraceIfUnused(binding.peerId, binding.traceId);
    }
  }

  /// Release one peer context if it still belongs to [traceId].
  void releasePeerTrace({required String peerId, String? traceId}) {
    _prune();
    final traces = _peerTraceIds[peerId];
    if (traces == null || traces.isEmpty) return;

    final resolvedTraceId = traceId;
    if (resolvedTraceId == null) {
      // A null trace is not permission to clear an ambiguous peer. This is
      // important when a stale terminal event races a newer connect.
      if (traces.length != 1) return;
      _removePeerTrace(peerId, traces.keys.single);
      return;
    }
    if (!traces.containsKey(resolvedTraceId)) return;
    _removePeerTrace(peerId, resolvedTraceId);
  }

  /// Release a completed peer operation while retaining a newer replacement.
  void completePeer(String peerId, {String? traceId}) {
    releasePeerTrace(peerId: peerId, traceId: traceId);
  }

  /// Release every context belonging to one operation trace.
  void releaseTrace(String traceId) {
    _prune();
    for (final peerId in _peerTraceIds.keys.toList(growable: false)) {
      _removePeerTrace(peerId, traceId, removeCommands: false);
    }
    for (final commandId in _commandTraceIds.keys.toList(growable: false)) {
      final bindings = _commandTraceIds[commandId]!;
      bindings.removeWhere((_, binding) => binding.traceId == traceId);
      if (bindings.isEmpty) _commandTraceIds.remove(commandId);
    }
  }

  /// Release all contexts.  The registry remains usable for an explicit
  /// owner reset; [dispose] is the terminal lifecycle boundary.
  void clear() {
    if (_disposed) return;
    _peerTraceIds.clear();
    _commandTraceIds.clear();
  }

  /// Dispose the owner and make late borrowers fail closed.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _peerTraceIds.clear();
    _commandTraceIds.clear();
  }

  void _removePeerTrace(
    String peerId,
    String traceId, {
    bool removeCommands = true,
  }) {
    final traces = _peerTraceIds[peerId];
    if (traces == null || !traces.containsKey(traceId)) return;
    traces.remove(traceId);
    if (traces.isEmpty) _peerTraceIds.remove(peerId);
    if (removeCommands) {
      for (final commandId in _commandTraceIds.keys.toList(growable: false)) {
        final bindings = _commandTraceIds[commandId]!;
        bindings.removeWhere(
          (_, binding) =>
              binding.peerId == peerId && binding.traceId == traceId,
        );
        if (bindings.isEmpty) _commandTraceIds.remove(commandId);
      }
    }
  }

  void _releasePeerTraceIfUnused(String peerId, String traceId) {
    final hasCommand = _commandTraceIds.values.any(
      (bindings) => bindings.values.any(
        (binding) => binding.peerId == peerId && binding.traceId == traceId,
      ),
    );
    if (!hasCommand) _removePeerTrace(peerId, traceId);
  }

  void _prune() {
    if (_disposed) return;
    final cutoff = _clock().subtract(bindingTtl);
    for (final peerId in _peerTraceIds.keys.toList(growable: false)) {
      final traces = _peerTraceIds[peerId]!;
      traces.removeWhere((_, touchedAt) => touchedAt.isBefore(cutoff));
      if (traces.isEmpty) _peerTraceIds.remove(peerId);
    }
    for (final commandId in _commandTraceIds.keys.toList(growable: false)) {
      final bindings = _commandTraceIds[commandId]!;
      bindings.removeWhere((_, binding) => binding.touchedAt.isBefore(cutoff));
      if (bindings.isEmpty) _commandTraceIds.remove(commandId);
    }
    _trimToCapacity();
  }

  void _trimToCapacity() {
    while (peerBindingCount + commandBindingCount > maxBindings) {
      String? oldestPeerId;
      String? oldestPeerTraceId;
      DateTime? oldestPeerAt;
      for (final entry in _peerTraceIds.entries) {
        for (final trace in entry.value.entries) {
          if (oldestPeerAt == null || trace.value.isBefore(oldestPeerAt)) {
            oldestPeerId = entry.key;
            oldestPeerTraceId = trace.key;
            oldestPeerAt = trace.value;
          }
        }
      }

      String? oldestCommandId;
      String? oldestCommandBindingKey;
      DateTime? oldestCommandAt;
      for (final entry in _commandTraceIds.entries) {
        for (final bindingEntry in entry.value.entries) {
          if (oldestCommandAt == null ||
              bindingEntry.value.touchedAt.isBefore(oldestCommandAt)) {
            oldestCommandId = entry.key;
            oldestCommandBindingKey = bindingEntry.key;
            oldestCommandAt = bindingEntry.value.touchedAt;
          }
        }
      }

      if (oldestPeerAt != null &&
          (oldestCommandAt == null || oldestPeerAt.isBefore(oldestCommandAt))) {
        _removePeerTrace(oldestPeerId!, oldestPeerTraceId!);
      } else if (oldestCommandId != null && oldestCommandBindingKey != null) {
        final bindings = _commandTraceIds[oldestCommandId]!;
        bindings.remove(oldestCommandBindingKey);
        if (bindings.isEmpty) _commandTraceIds.remove(oldestCommandId);
      } else {
        break;
      }
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('Telemetry trace registry is disposed.');
    }
  }

  static void _validate(String value, {required String field}) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, field, 'must not be empty');
    }
  }

  static String _commandBindingKey(String peerId, String traceId) =>
      '$peerId\u0000$traceId';
}

final class _CommandTraceBinding {
  _CommandTraceBinding({
    required this.peerId,
    required this.traceId,
    required this.touchedAt,
  });

  final String peerId;
  final String traceId;
  DateTime touchedAt;
}
