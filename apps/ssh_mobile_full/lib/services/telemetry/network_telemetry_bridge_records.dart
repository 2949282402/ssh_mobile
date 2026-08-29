part of 'network_telemetry_bridge.dart';

void _recordQuicConnected(
  NetworkTelemetryBridge bridge,
  String traceId,
  int? rttMs,
) {
  _pruneConnectedTraces(bridge);
  final now = bridge._clock();
  final previous = bridge._quicConnectedTraces[traceId];
  if (previous != null &&
      now.difference(previous) < bridge.traceRegistry.bindingTtl) {
    return;
  }
  _rememberConnectedTrace(bridge._quicConnectedTraces, traceId, now);
  _enqueueRecord(
    bridge,
    () => bridge.telemetryClient.record(
      event: TelemetryEvents.networkQuicConnected,
      traceId: traceId,
      properties: <String, dynamic>{
        'protocol_version': 'v2',
        if (rttMs != null && rttMs > 0) 'rtt_ms': rttMs,
      },
    ),
  );
}

void _recordRelayConnected(NetworkTelemetryBridge bridge, String traceId) {
  _pruneConnectedTraces(bridge);
  final now = bridge._clock();
  final previous = bridge._relayConnectedTraces[traceId];
  if (previous != null &&
      now.difference(previous) < bridge.traceRegistry.bindingTtl) {
    return;
  }
  _rememberConnectedTrace(bridge._relayConnectedTraces, traceId, now);
  _enqueueRecord(
    bridge,
    () => bridge.telemetryClient.record(
      event: TelemetryEvents.networkRelayConnected,
      traceId: traceId,
      properties: {'relay_region': _relayRegion()},
    ),
  );
}

void _rememberConnectedTrace(
  Map<String, DateTime> traces,
  String traceId,
  DateTime touchedAt,
) {
  traces[traceId] = touchedAt;
  if (traces.length <= NetworkTelemetryBridge._maxPeerContexts) return;
  final oldest = traces.entries.reduce(
    (left, right) => left.value.isBefore(right.value) ? left : right,
  );
  traces.remove(oldest.key);
}

void _pruneConnectedTraces(NetworkTelemetryBridge bridge) {
  final cutoff = bridge._clock().subtract(bridge.traceRegistry.bindingTtl);
  bridge._quicConnectedTraces.removeWhere(
    (_, touchedAt) => !touchedAt.isAfter(cutoff),
  );
  bridge._relayConnectedTraces.removeWhere(
    (_, touchedAt) => !touchedAt.isAfter(cutoff),
  );
}

void _recordQuicFailed(
  NetworkTelemetryBridge bridge,
  String traceId,
  NetworkError? error, {
  required bool fallbackUsed,
}) {
  final reason = error?.message ?? 'quic_failed';
  _enqueueRecord(
    bridge,
    () => bridge.telemetryClient.record(
      event: TelemetryEvents.networkQuicFailed,
      traceId: traceId,
      errorCode: _quicErrorCode(error),
      errorMessage: reason,
      properties: {'reason': reason, 'fallback_used': fallbackUsed},
    ),
  );
}

void _recordRelayFallbackReason(
  NetworkTelemetryBridge bridge,
  String traceId,
  String reason,
) {
  _enqueueRecord(
    bridge,
    () => bridge.telemetryClient.record(
      event: TelemetryEvents.networkRelayFallback,
      traceId: traceId,
      errorCode: TelemetryErrorCodes.netRelayUnavailable,
      errorMessage: reason,
      properties: {'direct_error': reason},
    ),
  );
}

void _recordRelayFailed(
  NetworkTelemetryBridge bridge,
  String traceId,
  String reason,
  bool fallbackUsed,
) {
  _enqueueRecord(
    bridge,
    () => bridge.telemetryClient.record(
      event: TelemetryEvents.networkRelayFailed,
      traceId: traceId,
      errorCode: TelemetryErrorCodes.netRelayUnavailable,
      errorMessage: reason,
      properties: {'reason': reason, 'fallback_used': fallbackUsed},
    ),
  );
}

void _enqueueRecord(
  NetworkTelemetryBridge bridge,
  Future<bool> Function() operation,
) {
  bridge._recordQueue = bridge._recordQueue.then<void>((_) async {
    try {
      await operation();
    } on Object {
      // A local telemetry write failure must not terminate the network event
      // subscription or prevent later spans from being recorded.
    }
  });
}

TelemetryErrorCodeDefinition _quicErrorCode(NetworkError? error) {
  if (error?.code == NetworkErrorCode.timeout) {
    return TelemetryErrorCodes.netQuicTimeout;
  }
  if (_isVerifiedQuicRefusal(error)) {
    return TelemetryErrorCodes.netQuicConnRefused;
  }
  return TelemetryErrorCodes.netQuicFailed;
}

bool _isVerifiedQuicRefusal(NetworkError? error) {
  if (error?.code != NetworkErrorCode.quicError) return false;
  final message = error!.message.trim().toLowerCase();
  return message.contains('refused');
}

/// 当前 Relay region 仅作为占位值；正式 region 由 relay 配置/Handshake
/// 返回后写入，避免把端点 URL 泄漏到遥测。
String _relayRegion() => 'unknown';
