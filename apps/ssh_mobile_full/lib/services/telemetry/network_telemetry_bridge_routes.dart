part of 'network_telemetry_bridge.dart';

void _handleNetworkEvent(NetworkTelemetryBridge bridge, SdkEvent event) {
  if (bridge._disposed) return;
  if (event case PeerStateChanged(
    :final peerId,
    :final state,
    :final routeType,
    :final routeTopology,
    :final routeTransport,
    :final error,
  )) {
    if (state == PeerConnectionState.connected) {
      final traceId = _traceForPeer(bridge, peerId);
      if (traceId != null) {
        if (routeType == NetworkRouteType.relay) {
          _recordRelayConnected(bridge, traceId);
        }
        // A direct connected event is followed by RouteChanged, which is
        // the only event carrying a measured RTT. Keep its trace alive
        // until that route observation arrives.
        if (routeType != NetworkRouteType.quicDirect) {
          _forgetPeer(bridge, peerId, traceId: traceId);
        }
      }
    } else if (state == PeerConnectionState.failed) {
      final traceId = _traceForPeer(bridge, peerId);
      final pending = traceId == null
          ? null
          : _pendingDirectFailureFor(bridge, peerId, traceId);
      if (traceId != null &&
          (pending != null ||
              _isDirectAttempt(
                routeType: routeType,
                routeTopology: routeTopology,
                routeTransport: routeTransport,
                error: error,
              ))) {
        if (pending != null) {
          _recordQuicFailed(
            bridge,
            traceId,
            pending.error,
            fallbackUsed: false,
          );
          bridge._recordedDirectFailures[pending.attemptId] = traceId;
          bridge._pendingDirectFailures.remove(pending.attemptId);
        } else if (!_hasRecordedDirectFailure(bridge, peerId, traceId)) {
          // Legacy/native peers may not emit the causal observation. A
          // terminal direct failure still records QUIC failure, but never
          // fabricates a Relay fallback without a fallback phase.
          _recordQuicFailed(bridge, traceId, error, fallbackUsed: false);
        }
        _forgetPeer(bridge, peerId, traceId: traceId);
      } else if (traceId != null) {
        _forgetPeer(bridge, peerId, traceId: traceId);
      }
    } else if (state == PeerConnectionState.disconnected) {
      final traceId = _traceForPeer(bridge, peerId);
      if (traceId != null) _forgetPeer(bridge, peerId, traceId: traceId);
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
      bridge,
      peerId: peerId,
      attemptId: attemptId,
      commandId: commandId,
      phase: phase,
      routeType: routeType,
      error: error,
    );
  } else if (event case RouteChanged(:final snapshot)) {
    _recordRouteEvaluated(bridge, snapshot);
  } else if (event case RelayStateChanged(:final state, :final error)) {
    if (state == RelayConnectionState.connected) {
      final traceId = _traceForRelay(bridge);
      if (traceId != null) _recordRelayConnected(bridge, traceId);
    } else if (state == RelayConnectionState.failed) {
      final traceId = _traceForRelay(bridge);
      final reason = error?.message ?? 'relay_failed';
      final fallbackUsed =
          error?.code == NetworkErrorCode.noRoute ||
          error?.code == NetworkErrorCode.relayError;
      if (traceId != null) {
        _recordRelayFailed(bridge, traceId, reason, fallbackUsed);
      }
      _clearRelayContext(bridge, traceId);
    } else if (state == RelayConnectionState.connecting) {
      final traceId = _traceForRelay(bridge);
      if (traceId != null) {
        bridge._relayTraceId = traceId;
      }
    }
  }
}

/// RouteChanged 表示路由评估完成，投影为 quic/relay connected 事件。
void _recordRouteEvaluated(
  NetworkTelemetryBridge bridge,
  SdkRouteSnapshot snapshot,
) {
  final traceId = _traceForPeer(bridge, snapshot.peerId);
  if (traceId == null) return;
  final rttMs = snapshot.rtt?.inMilliseconds ?? 0;

  switch (snapshot.routeType) {
    case NetworkRouteType.quicDirect:
      _recordQuicConnected(
        bridge,
        traceId,
        snapshot.rtt == null ? null : rttMs,
      );
      _forgetPeer(bridge, snapshot.peerId, traceId: traceId);
    case NetworkRouteType.relay:
      bridge._relayTraceId = traceId;
      bridge._relayPeerId = snapshot.peerId;
      _recordRelayConnected(bridge, traceId);
    case NetworkRouteType.lan:
    // LAN 直连不单独上报；保留 operation context 供后续失败事件关联。
    case NetworkRouteType.unspecified:
      // 路由未评估完成，不产生可聚合的事件。
      break;
  }
}

void _handleRouteAttempt(
  NetworkTelemetryBridge bridge, {
  required String peerId,
  required String attemptId,
  required String? commandId,
  required RouteAttemptPhase phase,
  required NetworkRouteType routeType,
  required NetworkError? error,
}) {
  _pruneLocalContexts(bridge);
  if (!_routeAttemptMatchesPhase(phase, routeType)) return;
  final traceId = _traceForRouteAttempt(bridge, peerId, attemptId, commandId);
  if (traceId == null) return;
  _rememberAttempt(
    bridge,
    attemptId,
    _BridgeAttemptContext(
      peerId: peerId,
      traceId: traceId,
      touchedAt: bridge._clock(),
    ),
  );

  switch (phase) {
    case RouteAttemptPhase.directFailed:
      bridge._pendingDirectFailures[attemptId] = _PendingDirectFailure(
        peerId: peerId,
        traceId: traceId,
        attemptId: attemptId,
        error: error,
        touchedAt: bridge._clock(),
      );
    case RouteAttemptPhase.relayFallbackStarted:
      final pending = bridge._pendingDirectFailures[attemptId];
      if (pending == null || pending.traceId != traceId) {
        // A missing DirectFailed event is still recoverable because the
        // fallback phase carries its direct error and command correlation.
        _recordQuicFailed(bridge, traceId, error, fallbackUsed: true);
      } else {
        _recordQuicFailed(bridge, traceId, pending.error, fallbackUsed: true);
        bridge._pendingDirectFailures.remove(attemptId);
      }
      bridge._recordedDirectFailures[attemptId] = traceId;
      bridge._relayTraceId = traceId;
      bridge._relayPeerId = peerId;
      _recordRelayFallbackReason(
        bridge,
        traceId,
        error?.message ?? 'direct route failed',
      );
    case RouteAttemptPhase.relayConnected:
      bridge._relayTraceId = traceId;
      bridge._relayPeerId = peerId;
    case RouteAttemptPhase.relayFailed:
      _recordRelayFailed(
        bridge,
        traceId,
        error?.message ?? 'relay_failed',
        true,
      );
      _clearRelayContext(bridge, traceId);
    case RouteAttemptPhase.unspecified:
      break;
  }
}

bool _routeAttemptMatchesPhase(
  RouteAttemptPhase phase,
  NetworkRouteType routeType,
) => switch (phase) {
  RouteAttemptPhase.directFailed => routeType == NetworkRouteType.quicDirect,
  RouteAttemptPhase.relayFallbackStarted ||
  RouteAttemptPhase.relayConnected ||
  RouteAttemptPhase.relayFailed => routeType == NetworkRouteType.relay,
  RouteAttemptPhase.unspecified => false,
};

bool _isDirectAttempt({
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
