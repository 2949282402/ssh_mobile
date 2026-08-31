part of 'network_telemetry_bridge.dart';

/// Resolve an attempt to the exact operation trace that created it. Command
/// correlation wins over peer-only context; ambiguous late results fail closed.
String? _traceForRouteAttempt(
  NetworkTelemetryBridge bridge,
  String peerId,
  String attemptId,
  String? commandId,
) {
  final known = bridge._attemptContexts[attemptId];
  final command = commandId;
  final commandTrace = _traceForCommand(bridge, command);
  if (command != null &&
      command.isNotEmpty &&
      commandTrace == null &&
      bridge.traceRegistry.hasCommandBinding(command)) {
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
    return bridge.traceRegistry.hasPeerTrace(peerId, known.traceId)
        ? known.traceId
        : null;
  }

  if (commandTrace != null) {
    _rememberPeer(bridge, peerId, commandTrace);
    return commandTrace;
  }

  return _traceForPeer(bridge, peerId);
}

String? _traceForCommand(NetworkTelemetryBridge bridge, String? commandId) {
  final command = commandId;
  if (command != null && command.isNotEmpty) {
    return bridge.traceRegistry.traceForCommand(command);
  }
  return null;
}

String? _traceForPeer(NetworkTelemetryBridge bridge, String peerId) {
  _pruneLocalContexts(bridge);
  final hasRegistryBinding = bridge.traceRegistry.hasPeerBinding(peerId);
  final registryTraceId = bridge.traceRegistry.traceForPeer(peerId);
  final local = bridge._peerContexts[peerId];
  if (hasRegistryBinding) {
    // If the peer has multiple in-flight traces, no peer-only event can be
    // attributed safely. If a new trace replaced a local one, the late old
    // event is equally ambiguous and must be dropped.
    if (registryTraceId == null ||
        (local != null && local.traceId != registryTraceId)) {
      return null;
    }
    _rememberPeer(bridge, peerId, registryTraceId);
    return registryTraceId;
  }
  if (local == null) return null;
  local.touchedAt = bridge._clock();
  return local.traceId;
}

String? _traceForRelay(NetworkTelemetryBridge bridge) {
  _pruneLocalContexts(bridge);
  final relayTrace = bridge._relayTraceId;
  if (relayTrace != null) {
    // Relay events have no peer id. Keep the previously established
    // operation only while its trace is still active and no competing trace
    // exists; this rejects a late old relay result after a new connect.
    if (!bridge.traceRegistry.hasTrace(relayTrace) ||
        bridge.traceRegistry.hasPeerTraceOtherThan(relayTrace)) {
      return null;
    }
    if (bridge._relayPeerId != null &&
        bridge.traceRegistry.traceForPeer(bridge._relayPeerId!) != relayTrace) {
      return null;
    }
    return relayTrace;
  }
  // RelayStateChanged has no peer/operation identity. Without a preceding
  // peer-scoped RouteAttempt or RouteChanged relay observation it may be a
  // control-plane reconnect and must not be attributed to an SSH span.
  return null;
}

void _rememberPeer(
  NetworkTelemetryBridge bridge,
  String peerId,
  String traceId,
) {
  bridge._peerContexts[peerId] = _BridgePeerContext(
    traceId: traceId,
    touchedAt: bridge._clock(),
  );
  if (bridge._peerContexts.length <= NetworkTelemetryBridge._maxPeerContexts) {
    return;
  }
  final oldest = bridge._peerContexts.entries.reduce(
    (left, right) =>
        left.value.touchedAt.isBefore(right.value.touchedAt) ? left : right,
  );
  bridge._peerContexts.remove(oldest.key);
}

void _rememberAttempt(
  NetworkTelemetryBridge bridge,
  String attemptId,
  _BridgeAttemptContext context,
) {
  bridge._attemptContexts[attemptId] = context;
  if (bridge._attemptContexts.length <=
      NetworkTelemetryBridge._maxPeerContexts) {
    return;
  }
  final oldest = bridge._attemptContexts.entries.reduce(
    (left, right) =>
        left.value.touchedAt.isBefore(right.value.touchedAt) ? left : right,
  );
  bridge._attemptContexts.remove(oldest.key);
  bridge._pendingDirectFailures.remove(oldest.key);
  bridge._recordedDirectFailures.remove(oldest.key);
}

void _forgetPeer(
  NetworkTelemetryBridge bridge,
  String peerId, {
  required String traceId,
}) {
  final local = bridge._peerContexts[peerId];
  if (local != null && local.traceId == traceId) {
    bridge._peerContexts.remove(peerId);
  }
  for (final attemptId in bridge._attemptContexts.keys.toList(
    growable: false,
  )) {
    final context = bridge._attemptContexts[attemptId];
    if (context?.peerId == peerId && context?.traceId == traceId) {
      bridge._pendingDirectFailures.remove(attemptId);
    }
  }
  bridge.traceRegistry.completePeer(peerId, traceId: traceId);
}

void _clearRelayContext(NetworkTelemetryBridge bridge, String? traceId) {
  // A relay event without a resolved trace may be a late result from an
  // older operation. It must never clear a newer operation's context.
  if (traceId != null && bridge._relayTraceId == traceId) {
    bridge._relayTraceId = null;
    bridge._relayPeerId = null;
  }
}

_PendingDirectFailure? _pendingDirectFailureFor(
  NetworkTelemetryBridge bridge,
  String peerId,
  String traceId,
) {
  for (final entry in bridge._pendingDirectFailures.entries) {
    final pending = entry.value;
    if (pending.peerId == peerId && pending.traceId == traceId) {
      return pending;
    }
  }
  return null;
}

bool _hasRecordedDirectFailure(
  NetworkTelemetryBridge bridge,
  String peerId,
  String traceId,
) {
  for (final entry in bridge._recordedDirectFailures.entries) {
    if (entry.value != traceId) continue;
    final context = bridge._attemptContexts[entry.key];
    if (context?.peerId == peerId && context?.traceId == traceId) return true;
  }
  return false;
}

void _pruneLocalContexts(NetworkTelemetryBridge bridge) {
  final cutoff = bridge._clock().subtract(bridge.traceRegistry.bindingTtl);
  bridge._peerContexts.removeWhere(
    (_, context) => !context.touchedAt.isAfter(cutoff),
  );
  bridge._attemptContexts.removeWhere(
    (_, context) => !context.touchedAt.isAfter(cutoff),
  );
  bridge._pendingDirectFailures.removeWhere(
    (_, pending) => !pending.touchedAt.isAfter(cutoff),
  );
  bridge._recordedDirectFailures.removeWhere(
    (attemptId, traceId) =>
        !bridge._attemptContexts.containsKey(attemptId) ||
        !bridge.traceRegistry.hasTrace(traceId),
  );
}
