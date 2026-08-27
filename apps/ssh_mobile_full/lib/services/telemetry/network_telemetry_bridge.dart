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
  });

  static const int _maxPeerContexts = 256;

  final TelemetryClient telemetryClient;
  final Stream<SdkEvent> _events;
  final TelemetryTraceRegistry traceRegistry;
  StreamSubscription<SdkEvent>? _subscription;
  bool _disposed = false;

  /// Trace context copied from the registry for late route events that do not
  /// carry a command id. A local context is used only after the registry has
  /// released the same operation; a newer registry binding always wins, and
  /// an ambiguous same-peer binding is ignored.
  final Map<String, _BridgePeerContext> _peerContexts =
      <String, _BridgePeerContext>{};
  String? _relayTraceId;
  String? _relayPeerId;
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
          _recordRouteConnected(routeType, traceId);
          _forgetPeer(peerId, traceId: traceId);
        }
      } else if (state == PeerConnectionState.failed) {
        final traceId = _traceForPeer(peerId);
        if (traceId != null &&
            _isDirectAttempt(
              routeType: routeType,
              routeTopology: routeTopology,
              routeTransport: routeTransport,
              error: error,
            )) {
          _recordQuicFailed(traceId, error);
          _recordRelayFallback(traceId, error);
          _relayTraceId = traceId;
          _relayPeerId = peerId;
        } else if (traceId != null) {
          _forgetPeer(peerId, traceId: traceId);
        }
      } else if (state == PeerConnectionState.disconnected) {
        final traceId = _traceForPeer(peerId);
        if (traceId != null) _forgetPeer(peerId, traceId: traceId);
      }
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
          _recordRelayFallbackReason(traceId, reason);
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
        _recordQuicConnected(traceId, rttMs);
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

  void _recordRouteConnected(NetworkRouteType routeType, String traceId) {
    switch (routeType) {
      case NetworkRouteType.quicDirect:
        _recordQuicConnected(traceId, 0);
      case NetworkRouteType.relay:
        _recordRelayConnected(traceId);
      case NetworkRouteType.lan:
      case NetworkRouteType.unspecified:
        break;
    }
  }

  String? _traceForPeer(String peerId) {
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
    local.touchedAt = DateTime.now();
    return local.traceId;
  }

  String? _traceForRelay() {
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
    final registryTrace = traceRegistry.traceForAnyPeer();
    if (registryTrace != null) return registryTrace;
    final traces = _peerContexts.values
        .map((context) => context.traceId)
        .toSet();
    return traces.length == 1 ? traces.single : null;
  }

  void _rememberPeer(String peerId, String traceId) {
    _peerContexts[peerId] = _BridgePeerContext(
      traceId: traceId,
      touchedAt: DateTime.now(),
    );
    if (_peerContexts.length <= _maxPeerContexts) return;
    final oldest = _peerContexts.entries.reduce(
      (left, right) =>
          left.value.touchedAt.isBefore(right.value.touchedAt) ? left : right,
    );
    _peerContexts.remove(oldest.key);
  }

  void _forgetPeer(String peerId, {required String traceId}) {
    final local = _peerContexts[peerId];
    if (local != null && local.traceId == traceId) {
      _peerContexts.remove(peerId);
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

  void _recordQuicConnected(String traceId, int rttMs) {
    _enqueueRecord(
      () => telemetryClient.record(
        event: TelemetryEvents.networkQuicConnected,
        traceId: traceId,
        properties: {'rtt_ms': rttMs, 'protocol_version': 'v2'},
      ),
    );
  }

  void _recordRelayConnected(String traceId) {
    final now = DateTime.now();
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

  void _recordQuicFailed(String traceId, NetworkError? error) {
    final reason = error?.message ?? 'quic_failed';
    _enqueueRecord(
      () => telemetryClient.record(
        event: TelemetryEvents.networkQuicFailed,
        traceId: traceId,
        errorCode: _quicErrorCode(error),
        errorMessage: reason,
        properties: {'reason': reason, 'fallback_used': true},
      ),
    );
  }

  void _recordRelayFallback(String traceId, NetworkError? error) {
    _recordRelayFallbackReason(traceId, error?.message ?? 'quic_failed');
  }

  void _recordRelayFallbackReason(String traceId, String reason) {
    _enqueueRecord(
      () => telemetryClient.record(
        event: TelemetryEvents.networkRelayFallback,
        traceId: traceId,
        errorCode: _quicErrorCodeFromReason(reason),
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

  static TelemetryErrorCodeDefinition _quicErrorCodeFromReason(String reason) {
    return reason.toLowerCase().contains('timed out')
        ? TelemetryErrorCodes.netQuicTimeout
        : TelemetryErrorCodes.netQuicConnRefused;
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
    _relayTraceId = null;
    _relayPeerId = null;
    _relayConnectedTraces.clear();
  }
}

final class _BridgePeerContext {
  _BridgePeerContext({required this.traceId, required this.touchedAt});

  final String traceId;
  DateTime touchedAt;
}
