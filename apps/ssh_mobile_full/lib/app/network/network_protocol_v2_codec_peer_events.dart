part of '../../services/network/network_protocol_v2_codec.dart';

/// 独占 Peer、Route、Relay 与 Presence 事件的类型化映射。
final class _PeerEventDecoder {
  const _PeerEventDecoder();

  PeerStateChanged decodeState(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var state = 0;
    var route = 0;
    var topology = 0;
    var transport = 0;
    NetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          state = reader.varint(field.wireType);
        case 3:
          route = reader.varint(field.wireType);
        case 4:
          error = _decodeNetworkError(reader.bytes(field.wireType));
        case 5:
          topology = reader.varint(field.wireType);
        case 6:
          transport = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return PeerStateChanged(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      state: PeerConnectionState.fromWire(state),
      routeType: NetworkRouteType.fromWire(route),
      routeTopology: NetworkRouteTopology.fromWire(topology),
      routeTransport: NetworkRouteTransport.fromWire(transport),
      error: error,
    );
  }

  RouteChanged decodeRouteChanged(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var route = 0;
    String? endpoint;
    int? rtt;
    int? loss;
    var topology = 0;
    var transport = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          route = reader.varint(field.wireType);
        case 3:
          endpoint = utf8.decode(reader.bytes(field.wireType));
        case 4:
          rtt = reader.varint(field.wireType);
        case 5:
          loss = reader.varint(field.wireType);
        case 6:
          topology = reader.varint(field.wireType);
        case 7:
          transport = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return RouteChanged(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      snapshot: RouteSnapshot(
        peerId: peerId,
        routeType: NetworkRouteType.fromWire(route),
        topology: NetworkRouteTopology.fromWire(topology),
        transport: NetworkRouteTransport.fromWire(transport),
        endpoint: endpoint,
        rtt: rtt == null ? null : Duration(milliseconds: rtt),
        loss: loss == null ? null : loss / 1000,
      ),
    );
  }

  RelayStateChanged decodeRelayStateChanged(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var state = 0;
    NetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          state = reader.varint(field.wireType);
        case 2:
          error = _decodeNetworkError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return RelayStateChanged(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      state: RelayConnectionState.fromWire(state),
      error: error,
    );
  }

  RouteAttemptChanged decodeRouteAttemptChanged(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var attemptId = '';
    var phase = 0;
    var route = 0;
    String? commandId;
    NetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          attemptId = utf8.decode(reader.bytes(field.wireType));
        case 3:
          phase = reader.varint(field.wireType);
        case 4:
          route = reader.varint(field.wireType);
        case 5:
          error = _decodeNetworkError(reader.bytes(field.wireType));
        case 6:
          commandId = utf8.decode(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return RouteAttemptChanged(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      attemptId: attemptId,
      phase: RouteAttemptPhase.fromWire(phase),
      routeType: NetworkRouteType.fromWire(route),
      commandId: commandId,
      error: error,
    );
  }

  PeerPresenceChanged decodePresence(
    String eventId,
    int timestampMs,
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
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          generation = reader.varint(field.wireType);
        case 3:
          state = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return PeerPresenceChanged(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      generation: generation,
      state: PeerPresenceState.fromWire(state),
    );
  }

  PeerPresenceSnapshot decodePresenceSnapshot(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    final peers = <PeerPresenceChanged>[];
    while (!reader.isDone) {
      final field = reader.field();
      if (field.number != 1) {
        reader.skip(field.wireType);
        continue;
      }
      final peerReader = _ProtoReader(reader.bytes(field.wireType));
      var peerId = '';
      var generation = 0;
      var state = 0;
      while (!peerReader.isDone) {
        final peerField = peerReader.field();
        switch (peerField.number) {
          case 1:
            peerId = utf8.decode(peerReader.bytes(peerField.wireType));
          case 2:
            generation = peerReader.varint(peerField.wireType);
          case 3:
            state = peerReader.varint(peerField.wireType);
          default:
            peerReader.skip(peerField.wireType);
        }
      }
      peers.add(
        PeerPresenceChanged(
          eventId: eventId,
          timestamp: _eventTimestamp(timestampMs),
          peerId: peerId,
          generation: generation,
          state: PeerPresenceState.fromWire(state),
        ),
      );
    }
    return PeerPresenceSnapshot(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      peers: peers,
    );
  }
}
