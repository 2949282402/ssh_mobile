part of 'native_realtime_protocol.dart';

/// Owns Dart/FFI identifier, payload, and stream-handle boundary mapping.

/// Owns Peer, route, Relay, presence, and environment event mapping.
final class _NativePeerEventDecoder {
  static const _values = _NativeProtocolValueMapper();

  static NativePeerLifecycleEvent _decodePeerLifecycle(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var state = 0;
    var policy = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          state = reader.varint(field.wireType);
        case 3:
          policy = reader.varint(field.wireType);
        case 4:
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    return NativePeerLifecycleEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      state: NativePeerState.fromWire(state),
      e2eePolicy: policy == NativeE2eePolicy.disabled.wireValue
          ? NativeE2eePolicy.disabled
          : NativeE2eePolicy.required,
      error: error,
    );
  }

  static NativePeerDiagnosticsEvent _decodePeerDiagnostics(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var state = 0;
    var policy = 0;
    var ready = 0;
    var queued = 0;
    var streams = 0;
    var transfers = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          state = reader.varint(field.wireType);
        case 3:
          policy = reader.varint(field.wireType);
        case 4:
          ready = reader.varint(field.wireType);
        case 5:
          queued = reader.varint(field.wireType);
        case 6:
          streams = reader.varint(field.wireType);
        case 7:
          transfers = reader.varint(field.wireType);
        case 8:
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    return NativePeerDiagnosticsEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      state: NativePeerState.fromWire(state),
      e2eePolicy: policy == NativeE2eePolicy.disabled.wireValue
          ? NativeE2eePolicy.disabled
          : NativeE2eePolicy.required,
      readyPathCount: ready,
      queuedCommandCount: queued,
      activeStreamCount: streams,
      activeTransferCount: transfers,
      lastError: error,
    );
  }

  static NativeNetworkEnvironmentChangedEvent _decodeEnvironmentChanged(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var generation = 0;
    var connectivity = false;
    var foreground = false;
    var metered = false;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          generation = reader.varint(field.wireType);
        case 2:
          connectivity = reader.varint(field.wireType) != 0;
        case 3:
          foreground = reader.varint(field.wireType) != 0;
        case 4:
          metered = reader.varint(field.wireType) != 0;
        default:
          reader.skip(field.wireType);
      }
    }
    return NativeNetworkEnvironmentChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      generation: generation,
      hasConnectivity: connectivity,
      isForeground: foreground,
      isMetered: metered,
    );
  }

  static NativePeerTransferProgressEvent _decodePeerTransferProgress(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var transferId = '';
    var offset = 0;
    var total = 0;
    var paused = false;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 3:
          offset = reader.varint(field.wireType);
        case 4:
          total = reader.varint(field.wireType);
        case 5:
          paused = reader.varint(field.wireType) != 0;
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
    return NativePeerTransferProgressEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      transferId: transferId,
      confirmedOffset: offset,
      totalBytes: total,
      paused: paused,
    );
  }

  static NativePeerStateChangedEvent _decodePeerState(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var state = 0;
    var route = 0;
    var topology = 0;
    var transport = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          state = reader.varint(field.wireType);
        case 3:
          route = reader.varint(field.wireType);
        case 4:
          error = _values.decodeError(reader.bytes(field.wireType));
        case 5:
          topology = reader.varint(field.wireType);
        case 6:
          transport = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    return NativePeerStateChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      state: NativePeerConnectionState.fromWire(state),
      routeType: NativeRouteType.fromWire(route),
      routeTopology: NativeRouteTopology.fromWire(topology),
      routeTransport: NativeRouteTransport.fromWire(transport),
      error: error,
    );
  }

  static NativeRouteAttemptChangedEvent _decodeRouteAttemptChanged(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var attemptId = '';
    var phase = 0;
    var route = 0;
    String? commandId;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          attemptId = reader.string(field.wireType, _maxCommandIdBytes);
        case 3:
          phase = reader.varint(field.wireType);
        case 4:
          route = reader.varint(field.wireType);
        case 5:
          error = _values.decodeError(reader.bytes(field.wireType));
        case 6:
          commandId = reader.string(field.wireType, _maxCommandIdBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    _values.validateDecodedIdentifier(attemptId, 'route attempt ID');
    return NativeRouteAttemptChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      attemptId: attemptId,
      phase: NativeRouteAttemptPhase.fromWire(phase),
      routeType: NativeRouteType.fromWire(route),
      commandId: commandId,
      error: error,
    );
  }

  static NativeRelayStateChangedEvent _decodeRelayState(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var state = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          state = reader.varint(field.wireType);
        case 2:
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return NativeRelayStateChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      state: NativeRelayConnectionState.fromWire(state),
      error: error,
    );
  }

  static NativePeerPresenceChangedEvent _decodePresenceChanged(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var generation = 0;
    var state = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          generation = reader.varint(field.wireType);
        case 3:
          state = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    return NativePeerPresenceChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      generation: generation,
      state: NativePeerPresenceState.fromWire(state),
    );
  }

  static NativePeerPresenceSnapshotEvent _decodePresenceSnapshot(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    final peers = <NativePeerPresenceChangedEvent>[];
    while (!reader.isDone) {
      final field = reader.field();
      if (field.number == 1) {
        if (peers.length >= 256) {
          throw const FormatException('Presence snapshot is too large.');
        }
        final nested = reader.bytes(field.wireType, _maxPeerIdBytes + 16);
        final peer = _decodePresenceChanged(
          eventId,
          timestampMs,
          protocolVersion,
          nested,
        );
        peers.add(peer);
      } else {
        reader.skip(field.wireType);
      }
    }
    return NativePeerPresenceSnapshotEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peers: List<NativePeerPresenceChangedEvent>.unmodifiable(peers),
    );
  }
}
