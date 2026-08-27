// 网络路由与回退生命周期遥测桥。
//
// 订阅 network_sdk 的 typed 事件流，把路由评估/回退观察映射为生成 contract
// 中已注册的网络遥测事件。直接连接与 Relay 失败分别使用对应的 typed
// TelemetryEvents 定义，避免业务代码复制 wire event names。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:network_sdk/network_sdk.dart';

import 'telemetry_span.dart';

/// 监听 [NetworkFacade.events] 并把网络路由生命周期投影为遥测事件。
///
/// 生命周期与 facade 对齐：由 Composition Root 在 telemetryClient 创建后构造，
/// 并调用 [attach]/[dispose] 与 facade 或 runtime 同步释放。所有 span 事件共享
/// SSH connect operation 的 traceId，保证 evaluated -> connected/fallback 端到端
/// 关联。Bridge 不拥有 trace registry，只借用并在释放时清除自己的观察状态。
final class NetworkTelemetryBridge {
  NetworkTelemetryBridge({
    required this.telemetryClient,
    required this._events,
    required this.traceRegistry,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const int _maxPeerContexts = 256;

  final TelemetryClient telemetryClient;
  final Stream<SdkEvent> _events;
  final TelemetryTraceRegistry traceRegistry;
  final DateTime Function() _clock;
  StreamSubscription<SdkEvent>? _subscription;
  bool _disposed = false;

  /// Trace context copied from the registry for late route events that do not
  /// carry a command id. A local context is used only after the registry has
  /// released the same operation; a newer registry binding always wins, and
  /// an ambiguous same-peer binding is ignored.
  final Map<String, _BridgePeerContext> _peerContexts =
      <String, _BridgePeerContext>{};
  final Map<String, _PendingDirectFailure> _pendingDirectFailures =
      <String, _PendingDirectFailure>{};
  final Map<String, _BridgeAttemptContext> _attemptContexts =
      <String, _BridgeAttemptContext>{};
  final Map<String, String> _recordedDirectFailures = <String, String>{};
  String? _relayTraceId;
  String? _relayPeerId;
  final Map<String, DateTime> _quicConnectedTraces = <String, DateTime>{};
  final Map<String, DateTime> _relayConnectedTraces = <String, DateTime>{};

  /// Records are serialized at the bridge boundary so event callbacks cannot
  /// reorder network spans. TelemetryClient also serializes all producers,
  /// which keeps SSH.started ahead of a native event even when both callers
  /// use fire-and-forget recording.
  Future<void> _recordQueue = Future<void>.value();

  /// 开始订阅事件流。
  void attach() {
    if (_disposed || _subscription != null) return;
    _subscription = _events.listen(
      _handleEvent,
      onError: (_) {
        // 事件流错误不终止遥测；保留 bag-of-events 槽位给后续 fallback 记录。
      },
    );
  }

  void _handleEvent(SdkEvent event) {
    if (_disposed) return;
    if (event case PeerStateChanged(
      :final peerId,
      :final state,
      :final routeType,
      :final routeTopology,
      :final routeTransport,
      :final error,
    )) {
      if (state == PeerConnectionState.connected) {
        final traceId = _traceForPeer(peerId);
        if (traceId != null) {
          if (routeType == NetworkRouteType.relay) {
            _recordRelayConnected(traceId);
          }
          // A direct connected event is followed by RouteChanged, which is
          // the only event carrying a measured RTT. Keep its trace alive
          // until that route observation arrives.
          if (routeType != NetworkRouteType.quicDirect) {
            _forgetPeer(peerId, traceId: traceId);
          }
        }
      } else if (state == PeerConnectionState.failed) {
        final traceId = _traceForPeer(peerId);
        final pending = traceId == null
            ? null
            : _pendingDirectFailureFor(peerId, traceId);
        if (traceId != null &&
            (pending != null ||
                _isDirectAttempt(
                  routeType: routeType,
                  routeTopology: routeTopology,
                  routeTransport: routeTransport,
                  error: error,
                ))) {
          if (pending != null) {
            _recordQuicFailed(traceId, pending.error, fallbackUsed: false);
            _recordedDirectFailures[pending.attemptId] = traceId;
            _pendingDirectFailures.remove(pending.attemptId);
          } else if (!_hasRecordedDirectFailure(peerId, traceId)) {
            // Legacy/native peers may not emit the causal observation. A
            // terminal direct failure still records QUIC failure, but never
            // fabricates a Relay fallback without a fallback phase.
            _recordQuicFailed(traceId, error, fallbackUsed: false);
          }
          _forgetPeer(peerId, traceId: traceId);
        } else if (traceId != null) {
          _forgetPeer(peerId, traceId: traceId);
        }
      } else if (state == PeerConnectionState.disconnected) {
        final traceId = _traceForPeer(peerId);
        if (traceId != null) _forgetPeer(peerId, traceId: traceId);
      }
    } else if (event case RouteAttemptChanged(
      :final peerId,
      :final attemptId,
      :final commandId,
      :final phase,
      :final routeType,
      :final error,
    )) {
      _handleRouteAttempt(
        peerId: peerId,
        attemptId: attemptId,
        commandId: commandId,
        phase: phase,
        routeType: routeType,
        error: error,
      );
    } else if (event case RouteChanged(:final snapshot)) {
      _recordRouteEvaluated(snapshot);
    } else if (event case RelayStateChanged(:final state, :final error)) {
      if (state == RelayConnectionState.connected) {
        final traceId = _traceForRelay();
        if (traceId != null) _recordRelayConnected(traceId);
      } else if (state == RelayConnectionState.failed) {
        final traceId = _traceForRelay();
        final reason = error?.message ?? 'relay_failed';
        final fallbackUsed =
            error?.code == NetworkErrorCode.noRoute ||
            error?.code == NetworkErrorCode.relayError;
        if (traceId != null) {
          _recordRelayFailed(traceId, reason, fallbackUsed);
        }
        _clearRelayContext(traceId);
      } else if (state == RelayConnectionState.connecting) {
        final traceId = _traceForRelay();
        if (traceId != null) {
          _relayTraceId = traceId;
        }
      }
    }
  }

  /// RouteChanged 表示路由评估完成，投影为 quic/relay connected 事件。
  void _recordRouteEvaluated(SdkRouteSnapshot snapshot) {
    final traceId = _traceForPeer(snapshot.peerId);
    if (traceId == null) return;
    final rttMs = snapshot.rtt?.inMilliseconds ?? 0;

    switch (snapshot.routeType) {
      case NetworkRouteType.quicDirect:
        _recordQuicConnected(traceId, snapshot.rtt == null ? null : rttMs);
        _forgetPeer(snapshot.peerId, traceId: traceId);
      case NetworkRouteType.relay:
        _relayTraceId = traceId;
        _relayPeerId = snapshot.peerId;
        _recordRelayConnected(traceId);
      case NetworkRouteType.lan:
      // LAN 直连不单独上报；保留 operation context 供后续失败事件关联。
      case NetworkRouteType.unspecified:
        // 路由未评估完成，不产生可聚合的事件。
        break;
    }
  }

  void _handleRouteAttempt({
    required String peerId,
    required String attemptId,
    required String? commandId,
    required RouteAttemptPhase phase,
    required NetworkRouteType routeType,
    required NetworkError? error,
  }) {
    _pruneLocalContexts();
    if (!_routeAttemptMatchesPhase(phase, routeType)) return;
    final traceId = _traceForRouteAttempt(peerId, attemptId, commandId);
    if (traceId == null) return;
    _rememberAttempt(
      attemptId,
      _BridgeAttemptContext(
        peerId: peerId,
        traceId: traceId,
        touchedAt: _clock(),
      ),
    );

    switch (phase) {
      case RouteAttemptPhase.directFailed:
        _pendingDirectFailures[attemptId] = _PendingDirectFailure(
          peerId: peerId,
          traceId: traceId,
          attemptId: attemptId,
          error: error,
          touchedAt: _clock(),
        );
      case RouteAttemptPhase.relayFallbackStarted:
        final pending = _pendingDirectFailures[attemptId];
        if (pending == null || pending.traceId != traceId) {
          // A missing DirectFailed event is still recoverable because the
          // fallback phase carries its direct error and command correlation.
          _recordQuicFailed(traceId, error, fallbackUsed: true);
        } else {
          _recordQuicFailed(traceId, pending.error, fallbackUsed: true);
          _pendingDirectFailures.remove(attemptId);
        }
        _recordedDirectFailures[attemptId] = traceId;
        _relayTraceId = traceId;
        _relayPeerId = peerId;
        _recordRelayFallbackReason(
          traceId,
          error?.message ?? 'direct route failed',
        );
      case RouteAttemptPhase.relayConnected:
        _relayTraceId = traceId;
        _relayPeerId = peerId;
      case RouteAttemptPhase.relayFailed:
        _recordRelayFailed(traceId, error?.message ?? 'relay_failed', true);
        _clearRelayContext(traceId);
      case RouteAttemptPhase.unspecified:
        break;
    }
  }

  String? _traceForRouteAttempt(
    String peerId,
    String attemptId,
    String? commandId,
  ) {
    final known = _attemptContexts[attemptId];
    final command = commandId;
    final commandTrace = _traceForCommand(command);
    if (command != null &&
        command.isNotEmpty &&
        commandTrace == null &&
        traceRegistry.hasCommandBinding(command)) {
      // A known command with no unique trace is a collision/ambiguous late
      // result. Falling back to peer identity would misattribute it.
      return null;
    }
    if (known != null) {
      if (known.peerId != peerId) return null;
      if (commandTrace != null) {
        return commandTrace == known.traceId ? known.traceId : null;
      }
      // The exact attempt context protects a late native event from being
      // attributed to a newer same-peer trace. If its operation has already
      // expired, drop the event rather than resurrecting stale telemetry.
      return traceRegistry.hasPeerTrace(peerId, known.traceId)
          ? known.traceId
          : null;
    }

    if (commandTrace != null) {
      _rememberPeer(peerId, commandTrace);
      return commandTrace;
    }

    return _traceForPeer(peerId);
  }

  String? _traceForCommand(String? commandId) {
    final command = commandId;
    if (command != null && command.isNotEmpty) {
      return traceRegistry.traceForCommand(command);
    }
    return null;
  }

  static bool _routeAttemptMatchesPhase(
    RouteAttemptPhase phase,
    NetworkRouteType routeType,
  ) {
    return switch (phase) {
      RouteAttemptPhase.directFailed =>
        routeType == NetworkRouteType.quicDirect,
      RouteAttemptPhase.relayFallbackStarted ||
      RouteAttemptPhase.relayConnected ||
      RouteAttemptPhase.relayFailed => routeType == NetworkRouteType.relay,
      RouteAttemptPhase.unspecified => false,
    };
  }

  String? _traceForPeer(String peerId) {
    _pruneLocalContexts();
    final hasRegistryBinding = traceRegistry.hasPeerBinding(peerId);
    final registryTraceId = traceRegistry.traceForPeer(peerId);
    final local = _peerContexts[peerId];
    if (hasRegistryBinding) {
      // If the peer has multiple in-flight traces, no peer-only event can be
      // attributed safely. If a new trace replaced a local one, the late old
      // event is equally ambiguous and must be dropped.
      if (registryTraceId == null ||
          (local != null && local.traceId != registryTraceId)) {
        return null;
      }
      _rememberPeer(peerId, registryTraceId);
      return registryTraceId;
    }
    if (local == null) return null;
    local.touchedAt = _clock();
    return local.traceId;
  }

  String? _traceForRelay() {
    _pruneLocalContexts();
    final relayTrace = _relayTraceId;
    if (relayTrace != null) {
      // Relay events have no peer id. Keep the previously established
      // operation only while its trace is still active and no competing trace
      // exists; this rejects a late old relay result after a new connect.
      if (!traceRegistry.hasTrace(relayTrace) ||
          traceRegistry.hasPeerTraceOtherThan(relayTrace)) {
        return null;
      }
      if (_relayPeerId != null &&
          traceRegistry.traceForPeer(_relayPeerId!) != relayTrace) {
        return null;
      }
      return relayTrace;
    }
    // RelayStateChanged has no peer/operation identity. Without a preceding
    // peer-scoped RouteAttempt or RouteChanged relay observation it may be a
    // control-plane reconnect and must not be attributed to an SSH span.
    return null;
  }

  void _rememberPeer(String peerId, String traceId) {
    _peerContexts[peerId] = _BridgePeerContext(
      traceId: traceId,
      touchedAt: _clock(),
    );
    if (_peerContexts.length <= _maxPeerContexts) return;
    final oldest = _peerContexts.entries.reduce(
      (left, right) =>
          left.value.touchedAt.isBefore(right.value.touchedAt) ? left : right,
    );
    _peerContexts.remove(oldest.key);
  }

  void _rememberAttempt(String attemptId, _BridgeAttemptContext context) {
    _attemptContexts[attemptId] = context;
    if (_attemptContexts.length <= _maxPeerContexts) return;
    final oldest = _attemptContexts.entries.reduce(
      (left, right) =>
          left.value.touchedAt.isBefore(right.value.touchedAt) ? left : right,
    );
    _attemptContexts.remove(oldest.key);
    _pendingDirectFailures.remove(oldest.key);
    _recordedDirectFailures.remove(oldest.key);
  }

  void _forgetPeer(String peerId, {required String traceId}) {
    final local = _peerContexts[peerId];
    if (local != null && local.traceId == traceId) {
      _peerContexts.remove(peerId);
    }
    for (final attemptId in _attemptContexts.keys.toList(growable: false)) {
      final context = _attemptContexts[attemptId];
      if (context?.peerId == peerId && context?.traceId == traceId) {
        _pendingDirectFailures.remove(attemptId);
      }
    }
    traceRegistry.completePeer(peerId, traceId: traceId);
  }

  void _clearRelayContext(String? traceId) {
    // A relay event without a resolved trace may be a late result from an
    // older operation. It must never clear a newer operation's context.
    if (traceId != null && _relayTraceId == traceId) {
      _relayTraceId = null;
      _relayPeerId = null;
    }
  }

  void _recordQuicConnected(String traceId, int? rttMs) {
    final now = _clock();
    final previous = _quicConnectedTraces[traceId];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 5)) {
      return;
    }
    _quicConnectedTraces[traceId] = now;
    _enqueueRecord(
      () => telemetryClient.record(
        event: TelemetryEvents.networkQuicConnected,
        traceId: traceId,
        properties: <String, dynamic>{
          'protocol_version': 'v2',
          if (rttMs != null && rttMs > 0) 'rtt_ms': rttMs,
        },
      ),
    );
  }

  void _recordRelayConnected(String traceId) {
    final now = _clock();
    final previous = _relayConnectedTraces[traceId];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 5)) {
      return;
    }
    _relayConnectedTraces[traceId] = now;
    if (_relayConnectedTraces.length > _maxPeerContexts) {
      final oldest = _relayConnectedTraces.entries.reduce(
        (left, right) => left.value.isBefore(right.value) ? left : right,
      );
      _relayConnectedTraces.remove(oldest.key);
    }
    _enqueueRecord(
      () => telemetryClient.record(
        event: TelemetryEvents.networkRelayConnected,
        traceId: traceId,
        properties: {'relay_region': _relayRegion()},
      ),
    );
  }

  void _recordQuicFailed(
    String traceId,
    NetworkError? error, {
    required bool fallbackUsed,
  }) {
    final reason = error?.message ?? 'quic_failed';
    _enqueueRecord(
      () => telemetryClient.record(
        event: TelemetryEvents.networkQuicFailed,
        traceId: traceId,
        errorCode: _quicErrorCode(error),
        errorMessage: reason,
        properties: {'reason': reason, 'fallback_used': fallbackUsed},
      ),
    );
  }

  void _recordRelayFallbackReason(String traceId, String reason) {
    _enqueueRecord(
      () => telemetryClient.record(
        event: TelemetryEvents.networkRelayFallback,
        traceId: traceId,
        errorCode: TelemetryErrorCodes.netRelayUnavailable,
        errorMessage: reason,
        properties: {'direct_error': reason},
      ),
    );
  }

  void _recordRelayFailed(String traceId, String reason, bool fallbackUsed) {
    _enqueueRecord(
      () => telemetryClient.record(
        event: TelemetryEvents.networkRelayFailed,
        traceId: traceId,
        errorCode: TelemetryErrorCodes.netRelayUnavailable,
        errorMessage: reason,
        properties: {'reason': reason, 'fallback_used': fallbackUsed},
      ),
    );
  }

  _PendingDirectFailure? _pendingDirectFailureFor(
    String peerId,
    String traceId,
  ) {
    for (final entry in _pendingDirectFailures.entries) {
      final pending = entry.value;
      if (pending.peerId == peerId && pending.traceId == traceId) {
        return pending;
      }
    }
    return null;
  }

  bool _hasRecordedDirectFailure(String peerId, String traceId) {
    for (final entry in _recordedDirectFailures.entries) {
      if (entry.value != traceId) continue;
      final context = _attemptContexts[entry.key];
      if (context?.peerId == peerId && context?.traceId == traceId) return true;
    }
    return false;
  }

  void _pruneLocalContexts() {
    final cutoff = _clock().subtract(traceRegistry.bindingTtl);
    _peerContexts.removeWhere(
      (_, context) => !context.touchedAt.isAfter(cutoff),
    );
    _attemptContexts.removeWhere(
      (_, context) => !context.touchedAt.isAfter(cutoff),
    );
    _pendingDirectFailures.removeWhere(
      (_, pending) => !pending.touchedAt.isAfter(cutoff),
    );
    _recordedDirectFailures.removeWhere(
      (attemptId, traceId) =>
          !_attemptContexts.containsKey(attemptId) ||
          !traceRegistry.hasTrace(traceId),
    );
  }

  void _enqueueRecord(Future<bool> Function() operation) {
    _recordQueue = _recordQueue.then<void>((_) async {
      try {
        await operation();
      } on Object {
        // A local telemetry write failure must not terminate the network event
        // subscription or prevent later spans from being recorded.
      }
    });
  }

  static bool _isDirectAttempt({
    required NetworkRouteType routeType,
    required NetworkRouteTopology routeTopology,
    required NetworkRouteTransport routeTransport,
    required NetworkError? error,
  }) {
    return routeType == NetworkRouteType.quicDirect ||
        routeTopology == NetworkRouteTopology.direct ||
        routeTransport == NetworkRouteTransport.quic ||
        error?.code == NetworkErrorCode.quicError ||
        error?.code == NetworkErrorCode.natError;
  }

  static TelemetryErrorCodeDefinition _quicErrorCode(NetworkError? error) {
    if (error?.code == NetworkErrorCode.timeout) {
      return TelemetryErrorCodes.netQuicTimeout;
    }
    return TelemetryErrorCodes.netQuicConnRefused;
  }

  /// 当前 Relay region 仅作为占位值；正式 region 由 relay 配置/Handshake
  /// 返回后写入，避免把端点 URL 泄漏到遥测。
  String _relayRegion() => 'unknown';

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    // The registry belongs to AppRuntime/connector. The bridge only drains
    // writes and drops its own copied contexts; it must not release a trace
    // still needed by another borrower.
    await _recordQueue;
    _peerContexts.clear();
    _pendingDirectFailures.clear();
    _attemptContexts.clear();
    _recordedDirectFailures.clear();
    _relayTraceId = null;
    _relayPeerId = null;
    _quicConnectedTraces.clear();
    _relayConnectedTraces.clear();
  }
}

final class _BridgePeerContext {
  _BridgePeerContext({required this.traceId, required this.touchedAt});

  final String traceId;
  DateTime touchedAt;
}

final class _BridgeAttemptContext {
  _BridgeAttemptContext({
    required this.peerId,
    required this.traceId,
    required this.touchedAt,
  });

  final String peerId;
  final String traceId;
  DateTime touchedAt;
}

final class _PendingDirectFailure {
  _PendingDirectFailure({
    required this.peerId,
    required this.traceId,
    required this.attemptId,
    required this.error,
    required this.touchedAt,
  });

  final String peerId;
  final String traceId;
  final String attemptId;
  final NetworkError? error;
  final DateTime touchedAt;
}
