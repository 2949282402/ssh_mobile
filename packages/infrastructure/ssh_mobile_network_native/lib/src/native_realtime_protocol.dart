// Native Network Protocol V2 Realtime command/event bindings.
//
// The Rust network-protocol crate remains the wire-contract owner. This file
// mirrors only the fields needed by the public native SDK facade and keeps
// protobuf framing, identifiers, and payload sizes bounded at the Dart edge.

import 'dart:convert';
import 'dart:typed_data';

const _protocolVersion = 2;
const _maxCommandIdBytes = 128;
const _maxEventIdBytes = 256;
const _maxPeerIdBytes = 128;
const _maxErrorMessageBytes = 8 * 1024;
const _realtimeIdBytes = 32;
const _maxRealtimePayloadBytes = 256 * 1024;
const _maxIceCandidateBytes = 8 * 1024;
const _maxEventBytes = 384 * 1024;
const _maxStreamServiceBytes = 128;
const _maxStreamId = 0xffff;
const _maxStreamDataBytes = 384 * 1024;
const _maxStreamHandleBytes = _maxPeerIdBytes + 16;
const _maxTransferIdBytes = 128;
const _maxFileNameBytes = 256;
const _maxChannelIdBytes = 128;
const _maxMessageIdBytes = 64;

/// Native peer lifecycle values mirrored from the frozen V2 wire.
enum NativePeerConnectionState {
  unspecified(0),
  connecting(1),
  connected(2),
  disconnected(3),
  failed(4);

  const NativePeerConnectionState(this.wireValue);

  final int wireValue;

  static NativePeerConnectionState fromWire(int value) =>
      NativePeerConnectionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => NativePeerConnectionState.unspecified,
      );
}

/// Native route metadata is kept as abstract enums; endpoint/socket values are
/// intentionally not part of the public typed event.
enum NativeRouteType {
  unspecified(0),
  quicDirect(1),
  relay(2),
  lan(4);

  const NativeRouteType(this.wireValue);

  final int wireValue;

  static NativeRouteType fromWire(int value) =>
      NativeRouteType.values.firstWhere(
        (route) => route.wireValue == value,
        orElse: () => NativeRouteType.unspecified,
      );
}

enum NativeRouteTopology {
  unspecified(0),
  direct(1),
  relay(2);

  const NativeRouteTopology(this.wireValue);

  final int wireValue;

  static NativeRouteTopology fromWire(int value) =>
      NativeRouteTopology.values.firstWhere(
        (topology) => topology.wireValue == value,
        orElse: () => NativeRouteTopology.unspecified,
      );
}

enum NativeRouteTransport {
  unspecified(0),
  quic(1),
  tcp(2),
  udp(3),
  webSocket(4);

  const NativeRouteTransport(this.wireValue);

  final int wireValue;

  static NativeRouteTransport fromWire(int value) =>
      NativeRouteTransport.values.firstWhere(
        (transport) => transport.wireValue == value,
        orElse: () => NativeRouteTransport.unspecified,
      );
}

enum NativeRelayConnectionState {
  unspecified(0),
  connecting(1),
  connected(2),
  disconnected(3),
  failed(4);

  const NativeRelayConnectionState(this.wireValue);

  final int wireValue;

  static NativeRelayConnectionState fromWire(int value) =>
      NativeRelayConnectionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => NativeRelayConnectionState.unspecified,
      );
}

const _maxPendingCommandResults = 64;

/// Native WebRTC Realtime session lifecycle states.
enum NativeRealtimeSessionState {
  unspecified(0),
  negotiating(1),
  connected(2),
  restarting(3),
  closed(4),
  failed(5);

  const NativeRealtimeSessionState(this.wireValue);

  /// Protobuf enumeration value used by Rust.
  final int wireValue;

  /// Converts an unknown wire value to [unspecified].
  static NativeRealtimeSessionState fromWire(int value) =>
      NativeRealtimeSessionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => NativeRealtimeSessionState.unspecified,
      );
}

/// Native WebRTC signaling kinds.
enum NativeRealtimeSignalKind {
  unspecified(0),
  webRtcOffer(1),
  webRtcAnswer(2),
  iceCandidate(3),
  iceRestart(4),
  webRtcClose(5);

  const NativeRealtimeSignalKind(this.wireValue);

  /// Protobuf enumeration value used by Rust.
  final int wireValue;

  /// Converts an unknown wire value to [unspecified].
  static NativeRealtimeSignalKind fromWire(int value) =>
      NativeRealtimeSignalKind.values.firstWhere(
        (kind) => kind.wireValue == value,
        orElse: () => NativeRealtimeSignalKind.unspecified,
      );
}

/// Native `RetryDisposition` wire values mirrored from Rust.
enum NativeRetryDisposition {
  unspecified(0),
  noRetry(1),
  retryWithBackoff(2),
  retryAfter(3),
  refreshCredentialThenRetry(4);

  const NativeRetryDisposition(this.wireValue);

  /// Protobuf enumeration value used by Rust.
  final int wireValue;

  /// Converts an unknown wire value to [unspecified].
  static NativeRetryDisposition fromWire(int value) =>
      NativeRetryDisposition.values.firstWhere(
        (disposition) => disposition.wireValue == value,
        orElse: () => NativeRetryDisposition.unspecified,
      );
}

/// A redacted, typed native network error.
final class NativeNetworkError {
  /// Creates a native network error value.
  const NativeNetworkError({
    required this.code,
    required this.message,
    this.operation,
    this.peerId,
    this.retryDisposition = NativeRetryDisposition.unspecified,
    this.retryAfterSeconds = 0,
  });

  /// Rust `NetworkErrorCode` wire value.
  final int code;

  /// Human-readable operation error without secret payloads.
  final String message;

  /// Native operation name, when present.
  final String? operation;

  /// Related peer identifier, when present.
  final String? peerId;

  /// Server-suggested retry policy; [NativeRetryDisposition.unspecified] means
  /// unspecified.
  final NativeRetryDisposition retryDisposition;

  /// Server-suggested `RetryAfter` seconds; 0 means unspecified.
  final int retryAfterSeconds;
}

/// Base class for typed events emitted by [NativeNetworkRuntime.events].
sealed class NativeNetworkEvent {
  /// Creates a typed event envelope.
  const NativeNetworkEvent({
    required this.eventId,
    required this.timestampMs,
    required this.protocolVersion,
  });

  /// Native event identifier.
  final String eventId;

  /// Native event timestamp in Unix milliseconds.
  final int timestampMs;

  /// Protocol version carried by the native event.
  final int protocolVersion;
}

/// Result of a command accepted or rejected by the native worker.
final class NativeCommandResultEvent extends NativeNetworkEvent {
  /// Creates a command result event.
  const NativeCommandResultEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.commandId,
    required this.accepted,
    this.error,
  });

  /// Command identifier supplied in the command envelope.
  final String commandId;

  /// Whether the worker accepted the command for execution.
  final bool accepted;

  /// Structured rejection, when [accepted] is false.
  final NativeNetworkError? error;
}

/// Peer-scoped native state event.  The endpoint and concrete carrier remain
/// native diagnostics and are not exposed here.
final class NativePeerStateChangedEvent extends NativeNetworkEvent {
  const NativePeerStateChangedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.state,
    required this.routeType,
    this.routeTopology = NativeRouteTopology.unspecified,
    this.routeTransport = NativeRouteTransport.unspecified,
    this.error,
  });

  final String peerId;
  final NativePeerConnectionState state;
  final NativeRouteType routeType;
  final NativeRouteTopology routeTopology;
  final NativeRouteTransport routeTransport;
  final NativeNetworkError? error;
}

/// Native transfer progress.  The frozen V2 event has no peer field; the
/// optional field makes that schema gap explicit instead of inventing scope.
final class NativeTransferProgressEvent extends NativeNetworkEvent {
  const NativeTransferProgressEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.transferId,
    required this.bytesTransferred,
    required this.totalBytes,
    this.peerId,
  });

  final String transferId;
  final int bytesTransferred;
  final int totalBytes;
  final String? peerId;
}

/// Transfer offer with the peer scope present in the frozen wire.
final class NativeIncomingTransferOfferEvent extends NativeNetworkEvent {
  const NativeIncomingTransferOfferEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.fileSize,
    required this.routeType,
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
  final NativeRouteType routeType;
}

/// Transfer completion.  The V2 wire does not carry peer scope.
final class NativeTransferCompletedEvent extends NativeNetworkEvent {
  const NativeTransferCompletedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.transferId,
    required this.localPath,
    this.peerId,
  });

  final String transferId;
  final String localPath;
  final String? peerId;
}

/// Transfer failure.  The V2 wire does not carry peer scope outside its
/// nested error, so adapters must not infer it from a path or route.
final class NativeTransferFailedEvent extends NativeNetworkEvent {
  const NativeTransferFailedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.transferId,
    required this.error,
    this.peerId,
  });

  final String transferId;
  final NativeNetworkError? error;
  final String? peerId;
}

/// Relay lifecycle event without exposing its WebSocket or credential.
final class NativeRelayStateChangedEvent extends NativeNetworkEvent {
  const NativeRelayStateChangedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.state,
    this.error,
  });

  final NativeRelayConnectionState state;
  final NativeNetworkError? error;
}

/// Peer-scoped reliable message event with a bounded opaque payload.
final class NativeChannelMessageEvent extends NativeNetworkEvent {
  NativeChannelMessageEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.sessionId,
    required this.channelId,
    required this.messageId,
    required this.sequence,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload);

  final String peerId;
  final String sessionId;
  final String channelId;
  final Uint8List messageId;
  final int sequence;
  final Uint8List payload;
}

/// Peer-scoped application acknowledgement.
final class NativeDeliveryAckedEvent extends NativeNetworkEvent {
  NativeDeliveryAckedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.sessionId,
    required Uint8List messageId,
    required this.recoveryEpoch,
  }) : messageId = Uint8List.fromList(messageId);

  final String peerId;
  final String sessionId;
  final Uint8List messageId;
  final int recoveryEpoch;
}

/// Presence is a hint, not connectivity truth.
final class NativePeerPresenceChangedEvent extends NativeNetworkEvent {
  const NativePeerPresenceChangedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.generation,
    required this.state,
  });

  final String peerId;
  final int generation;
  final NativePeerPresenceState state;
}

enum NativePeerPresenceState {
  unspecified(0),
  online(1),
  updated(2),
  offline(3);

  const NativePeerPresenceState(this.wireValue);

  final int wireValue;

  static NativePeerPresenceState fromWire(int value) =>
      NativePeerPresenceState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => NativePeerPresenceState.unspecified,
      );
}

/// Full presence snapshot; it remains a hint and carries no path details.
final class NativePeerPresenceSnapshotEvent extends NativeNetworkEvent {
  const NativePeerPresenceSnapshotEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peers,
  });

  final List<NativePeerPresenceChangedEvent> peers;
}

/// Correlates registered commands with exactly one terminal result.
///
/// A native worker may retry or duplicate an event at a transport boundary,
/// but a public command must complete at most once. Call [register] before
/// submitting a command, pass every decoded event through [filterEvent], and
/// call [cancel] when queue acceptance fails or the owner cancels the command.
/// Unknown and duplicate command results are dropped. Pending registrations
/// are bounded so a missing result cannot grow this guard without limit.
final class NativeCommandResultGuard {
  /// Creates a guard with a bounded number of in-flight command IDs.
  NativeCommandResultGuard({
    this.maxPendingCommands = _maxPendingCommandResults,
  }) : assert(maxPendingCommands > 0) {
    if (maxPendingCommands <= 0) {
      throw ArgumentError.value(
        maxPendingCommands,
        'maxPendingCommands',
        'Must be positive.',
      );
    }
  }

  /// Maximum number of commands that may await a terminal result.
  final int maxPendingCommands;
  final Set<String> _pendingCommandIds = <String>{};

  /// Number of commands still waiting for a terminal result.
  int get pendingCount => _pendingCommandIds.length;

  /// Registers [commandId] before queue submission.
  ///
  /// Returns `false` for a duplicate ID or when the bounded pending budget is
  /// exhausted. The caller must not submit a command when registration fails.
  bool register(String commandId) {
    if (commandId.isEmpty ||
        utf8.encode(commandId).length > _maxCommandIdBytes) {
      throw ArgumentError.value(
        commandId,
        'commandId',
        'Must contain 1-$_maxCommandIdBytes bytes.',
      );
    }
    if (_pendingCommandIds.contains(commandId) ||
        _pendingCommandIds.length >= maxPendingCommands) {
      return false;
    }
    _pendingCommandIds.add(commandId);
    return true;
  }

  /// Cancels a command that will not produce a terminal result.
  void cancel(String commandId) => _pendingCommandIds.remove(commandId);

  /// Keeps non-result events and admits only the first result for a registered
  /// command. Returns `null` for unknown or duplicate command results.
  NativeNetworkEvent? filterEvent(NativeNetworkEvent event) {
    if (event is! NativeCommandResultEvent) return event;
    if (!_pendingCommandIds.remove(event.commandId)) return null;
    return event;
  }

  /// Drops all pending registrations during owner shutdown.
  void clear() => _pendingCommandIds.clear();
}

/// Realtime session state event.
final class NativeRealtimeStateChangedEvent extends NativeNetworkEvent {
  /// Creates a realtime state event.
  const NativeRealtimeStateChangedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.realtimeId,
    required this.peerId,
    required this.state,
    required this.revision,
    this.error,
  });

  /// Stable 16-byte lowercase hexadecimal realtime session identifier.
  final String realtimeId;

  /// Remote peer identifier.
  final String peerId;

  /// Current native realtime state.
  final NativeRealtimeSessionState state;

  /// Signaling revision associated with this state.
  final int revision;

  /// Structured failure, when [state] is failed.
  final NativeNetworkError? error;
}

/// Realtime session state snapshot published once the session is stable.
final class NativeRealtimeSnapshotEvent extends NativeNetworkEvent {
  /// Creates a realtime snapshot event.
  const NativeRealtimeSnapshotEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.realtimeId,
    required this.peerId,
    required this.state,
    required this.revision,
    this.error,
  });

  /// Stable 16-byte lowercase hexadecimal realtime session identifier.
  final String realtimeId;

  /// Remote peer identifier.
  final String peerId;

  /// Current native realtime state.
  final NativeRealtimeSessionState state;

  /// Signaling revision associated with this snapshot.
  final int revision;

  /// Structured failure, when [state] is failed.
  final NativeNetworkError? error;
}

/// Realtime signaling event containing bounded SDP/ICE opaque bytes.
final class NativeRealtimeSignalEvent extends NativeNetworkEvent {
  /// Creates a realtime signaling event.
  NativeRealtimeSignalEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.realtimeId,
    required this.peerId,
    required this.kind,
    required this.revision,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload);

  /// Stable 16-byte lowercase hexadecimal realtime session identifier.
  final String realtimeId;

  /// Remote peer identifier.
  final String peerId;

  /// Signaling message kind.
  final NativeRealtimeSignalKind kind;

  /// Signaling revision associated with the message.
  final int revision;

  /// SDP, ICE, or close control bytes. Never a media/file data frame.
  final Uint8List payload;
}

/// Stable business identity for a logical ReliableStream.
///
/// `streamId` is only unique within the opener device namespace.
final class NativeStreamHandle {
  /// Creates a logical stream handle.
  const NativeStreamHandle({
    required this.openerDeviceId,
    required this.streamId,
  });

  /// Device ID of the side that opened the logical stream.
  final String openerDeviceId;

  /// Numeric stream ID within the opener device namespace.
  final int streamId;

  @override
  bool operator ==(Object other) =>
      other is NativeStreamHandle &&
      other.openerDeviceId == openerDeviceId &&
      other.streamId == streamId;

  @override
  int get hashCode => Object.hash(openerDeviceId, streamId);
}

/// ReliableStream 收到对端字节后发布的事件（network-protocol tag 26）。
final class NativeSshStreamDataReceivedEvent extends NativeNetworkEvent {
  /// Creates an SSH stream data event.
  NativeSshStreamDataReceivedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.handle,
    required Uint8List data,
  }) : data = Uint8List.fromList(data);

  /// Remote peer identifier.
  final String peerId;

  /// Stable identity of the logical stream.
  final NativeStreamHandle handle;

  /// Opener device ID, retained as a convenience view of [handle].
  String get openerDeviceId => handle.openerDeviceId;

  /// Logical stream identifier, retained as a convenience view of [handle].
  int get streamId => handle.streamId;

  /// Opaque SSH/SFTP protocol bytes.
  final Uint8List data;
}

/// ReliableStream 关闭事件（network-protocol tag 27）。
final class NativeSshStreamClosedEvent extends NativeNetworkEvent {
  /// Creates an SSH stream closed event.
  const NativeSshStreamClosedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.handle,
  });

  /// Remote peer identifier.
  final String peerId;

  /// Stable identity of the logical stream.
  final NativeStreamHandle handle;

  /// Opener device ID, retained as a convenience view of [handle].
  String get openerDeviceId => handle.openerDeviceId;

  /// Logical stream identifier, retained as a convenience view of [handle].
  int get streamId => handle.streamId;
}

/// Bounded Protobuf command/event codec for the native Realtime API.
final class NativeNetworkProtocol {
  /// Current native protocol version.
  static const int protocolVersion = _protocolVersion;

  const NativeNetworkProtocol._();

  /// Encodes a Peer connect request using the existing V2 command envelope.
  /// The v2 adapter supplies the business requirement, not a concrete socket.
  static Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
    int intent = 0,
    int communicationClass = 2,
  }) {
    _validateCommandId(commandId);
    _validatePeerId(peerId);
    if (intent < 0 || communicationClass < 0 || communicationClass > 5) {
      throw ArgumentError.value(
        communicationClass,
        'communicationClass',
        'Communication class is outside the frozen wire range.',
      );
    }
    return _command(
      commandId,
      10,
      (_ProtoWriter()
            ..string(1, peerId)
            ..varint(2, intent)
            ..varint(3, communicationClass))
          .takeBytes(),
    );
  }

  /// Encodes a Peer disconnect request using the existing V2 command.
  static Uint8List disconnectPeerCommand({
    required String commandId,
    required String peerId,
  }) {
    _validateCommandId(commandId);
    _validatePeerId(peerId);
    return _command(
      commandId,
      17,
      (_ProtoWriter()..string(1, peerId)).takeBytes(),
    );
  }

  /// Encodes a reliable message through the existing V2 tag 19.
  ///
  /// The frozen command does not carry `message_id`; the Delivery owner must
  /// provide that business identity at the next schema seam.
  static Uint8List sendMessageCommand({
    required String commandId,
    required String peerId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
  }) {
    _validateCommandId(commandId);
    _validatePeerId(peerId);
    if (channelId.isEmpty || _utf8ByteLength(channelId) > _maxChannelIdBytes) {
      throw ArgumentError.value(
        channelId,
        'channelId',
        'Channel ID is invalid.',
      );
    }
    if (payload.length > _maxEventBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'Payload is too large.',
      );
    }
    return _command(
      commandId,
      19,
      (_ProtoWriter()
            ..string(1, peerId)
            ..string(2, channelId)
            ..bytesField(3, payload)
            ..varint(4, deliveryPolicy))
          .takeBytes(),
    );
  }

  /// Encodes a transfer request through the existing V2 tag 11.
  static Uint8List sendFileCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
  }) {
    _validateCommandId(commandId);
    _validatePeerId(peerId);
    _validateIdentifier(transferId, 'transferId', _maxTransferIdBytes);
    _validateIdentifier(filePath, 'filePath', _maxEventBytes);
    return _command(
      commandId,
      11,
      (_ProtoWriter()
            ..string(1, transferId)
            ..string(2, peerId)
            ..string(3, filePath))
          .takeBytes(),
    );
  }

  /// Encodes a transfer cancellation through the existing V2 tag 12.
  static Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) {
    _validateCommandId(commandId);
    _validateIdentifier(transferId, 'transferId', _maxTransferIdBytes);
    return _command(
      commandId,
      12,
      (_ProtoWriter()..string(1, transferId)).takeBytes(),
    );
  }

  /// Encodes `StartRealtimeSession` into the V2 command envelope.
  static Uint8List startRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
  }) {
    _validateCommandId(commandId);
    _validateRealtimeId(realtimeId);
    _validatePeerId(peerId);
    return _command(
      commandId,
      21,
      (_ProtoWriter()
            ..string(1, realtimeId)
            ..string(2, peerId))
          .takeBytes(),
    );
  }

  /// Encodes `StopRealtimeSession` into the V2 command envelope.
  static Uint8List stopRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
  }) {
    _validateCommandId(commandId);
    _validateRealtimeId(realtimeId);
    return _command(
      commandId,
      22,
      (_ProtoWriter()..string(1, realtimeId)).takeBytes(),
    );
  }

  /// Encodes `SendRealtimeSignal` into the V2 command envelope.
  static Uint8List sendRealtimeSignalCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required NativeRealtimeSignalKind kind,
    required int revision,
    required Uint8List payload,
  }) {
    _validateCommandId(commandId);
    _validateRealtimeId(realtimeId);
    _validatePeerId(peerId);
    if (kind == NativeRealtimeSignalKind.unspecified) {
      throw ArgumentError.value(
        kind,
        'kind',
        'A concrete signal kind is required.',
      );
    }
    if (revision <= 0) {
      throw ArgumentError.value(revision, 'revision', 'Must be positive.');
    }
    _validateSignalPayload(kind, payload);
    return _command(
      commandId,
      23,
      (_ProtoWriter()
            ..string(1, realtimeId)
            ..string(2, peerId)
            ..varint(3, kind.wireValue)
            ..varint(4, revision)
            ..bytesField(5, payload))
          .takeBytes(),
    );
  }

  /// Encodes `SshStreamOpen` into the V2 command envelope (tag 25).
  static Uint8List sshStreamOpenCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    String service = 'ssh',
  }) {
    _validateCommandId(commandId);
    _validatePeerId(peerId);
    _validateStreamHandle(handle);
    _validateStreamService(service);
    return _command(
      commandId,
      25,
      (_ProtoWriter()
            ..string(1, peerId)
            ..message(2, _encodeStreamHandle(handle))
            ..string(3, service))
          .takeBytes(),
    );
  }

  /// Encodes `SshStreamData` into the V2 command envelope (tag 26).
  static Uint8List sshStreamDataCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required Uint8List data,
  }) {
    _validateCommandId(commandId);
    _validatePeerId(peerId);
    _validateStreamHandle(handle);
    if (data.length > _maxStreamDataBytes) {
      throw ArgumentError.value(
        data.length,
        'data',
        'SSH stream data is too large.',
      );
    }
    return _command(
      commandId,
      26,
      (_ProtoWriter()
            ..string(1, peerId)
            ..message(2, _encodeStreamHandle(handle))
            ..bytesField(3, data))
          .takeBytes(),
    );
  }

  /// Encodes `SshStreamClose` into the V2 command envelope (tag 27).
  static Uint8List sshStreamCloseCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) {
    _validateCommandId(commandId);
    _validatePeerId(peerId);
    _validateStreamHandle(handle);
    return _command(
      commandId,
      27,
      (_ProtoWriter()
            ..string(1, peerId)
            ..message(2, _encodeStreamHandle(handle)))
          .takeBytes(),
    );
  }

  /// Decodes a native event. Unknown event payloads return null so a newer
  /// Rust event cannot terminate the public typed stream.
  static NativeNetworkEvent? decodeEvent(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > _maxEventBytes) {
      throw const FormatException('Native event is outside size bounds.');
    }
    final reader = _ProtoReader(bytes);
    var eventId = '';
    var timestampMs = 0;
    var protocolVersion = 0;
    int? payloadField;
    Uint8List? payload;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          eventId = reader.string(field.wireType, _maxEventIdBytes);
        case 2:
          timestampMs = reader.varint(field.wireType);
        case 3:
          protocolVersion = reader.varint(field.wireType);
        case 13:
        case 10:
        case 11:
        case 14:
        case 15:
        case 16:
        case 18:
        case 19:
        case 20:
        case 24:
        case 25:
        case 21:
        case 22:
        case 23:
        case 26:
        case 27:
          payloadField = field.number;
          payload = reader.bytes(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    if (eventId.isEmpty) {
      throw const FormatException('Native event has no event ID.');
    }
    if (protocolVersion != _protocolVersion) {
      throw FormatException(
        'Unsupported native protocol version: $protocolVersion.',
      );
    }
    final eventPayload = payload;
    final fieldNumber = payloadField;
    if (eventPayload == null || fieldNumber == null) return null;
    return switch (fieldNumber) {
      10 => _decodePeerState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      11 => _decodeTransferProgress(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      13 => _decodeCommandResult(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      14 => _decodeIncomingTransferOffer(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      15 => _decodeTransferCompleted(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      16 => _decodeTransferFailed(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      18 => _decodeRelayState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      19 => _decodeChannelMessage(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      20 => _decodeDeliveryAcked(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      21 => _decodeRealtimeState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      24 => _decodePresenceChanged(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      25 => _decodePresenceSnapshot(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      22 => _decodeRealtimeSignal(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      23 => _decodeRealtimeSnapshot(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      26 => _decodeSshStreamData(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      27 => _decodeSshStreamClosed(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      _ => null,
    };
  }

  static Uint8List _command(String commandId, int field, Uint8List payload) =>
      (_ProtoWriter()
            ..string(1, commandId)
            ..varint(2, _protocolVersion)
            ..message(field, payload))
          .takeBytes();

  static NativeCommandResultEvent _decodeCommandResult(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var commandId = '';
    var accepted = false;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          commandId = reader.string(field.wireType, _maxCommandIdBytes);
        case 2:
          accepted = reader.varint(field.wireType) != 0;
        case 3:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    if (commandId.isEmpty) {
      throw const FormatException('Native command result has no command ID.');
    }
    return NativeCommandResultEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      commandId: commandId,
      accepted: accepted,
      error: error,
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
          error = _decodeError(reader.bytes(field.wireType));
        case 5:
          topology = reader.varint(field.wireType);
        case 6:
          transport = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedPeerId(peerId);
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

  static NativeTransferProgressEvent _decodeTransferProgress(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var bytesTransferred = 0;
    var totalBytes = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 2:
          bytesTransferred = reader.varint(field.wireType);
        case 3:
          totalBytes = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedIdentifier(transferId, 'transfer ID');
    return NativeTransferProgressEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
    );
  }

  static NativeIncomingTransferOfferEvent _decodeIncomingTransferOffer(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var peerId = '';
    var fileName = '';
    var fileSize = 0;
    var route = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          fileName = reader.string(field.wireType, _maxFileNameBytes);
        case 4:
          fileSize = reader.varint(field.wireType);
        case 5:
          route = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedIdentifier(transferId, 'transfer ID');
    _validateDecodedPeerId(peerId);
    _validateDecodedIdentifier(fileName, 'file name');
    return NativeIncomingTransferOfferEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
      peerId: peerId,
      fileName: fileName,
      fileSize: fileSize,
      routeType: NativeRouteType.fromWire(route),
    );
  }

  static NativeTransferCompletedEvent _decodeTransferCompleted(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var localPath = '';
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 2:
          localPath = reader.string(field.wireType, _maxEventBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedIdentifier(transferId, 'transfer ID');
    return NativeTransferCompletedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
      localPath: localPath,
    );
  }

  static NativeTransferFailedEvent _decodeTransferFailed(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 2:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedIdentifier(transferId, 'transfer ID');
    return NativeTransferFailedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
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
          error = _decodeError(reader.bytes(field.wireType));
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

  static NativeChannelMessageEvent _decodeChannelMessage(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var sessionId = '';
    var channelId = '';
    var messageId = Uint8List(0);
    var sequence = 0;
    var payload = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          sessionId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          channelId = reader.string(field.wireType, _maxChannelIdBytes);
        case 4:
          messageId = reader.bytes(field.wireType, _maxMessageIdBytes);
        case 5:
          sequence = reader.varint(field.wireType);
        case 7:
          payload = reader.bytes(field.wireType, _maxEventBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedPeerId(peerId);
    _validateDecodedIdentifier(sessionId, 'session ID');
    _validateDecodedIdentifier(channelId, 'channel ID');
    if (messageId.isEmpty) {
      throw const FormatException('Channel message has no message ID.');
    }
    return NativeChannelMessageEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      sessionId: sessionId,
      channelId: channelId,
      messageId: messageId,
      sequence: sequence,
      payload: payload,
    );
  }

  static NativeDeliveryAckedEvent _decodeDeliveryAcked(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var sessionId = '';
    var messageId = Uint8List(0);
    var recoveryEpoch = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          sessionId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          messageId = reader.bytes(field.wireType, _maxMessageIdBytes);
        case 4:
          recoveryEpoch = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedPeerId(peerId);
    _validateDecodedIdentifier(sessionId, 'session ID');
    if (messageId.isEmpty) {
      throw const FormatException('Delivery ACK has no message ID.');
    }
    return NativeDeliveryAckedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      sessionId: sessionId,
      messageId: messageId,
      recoveryEpoch: recoveryEpoch,
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
    _validateDecodedPeerId(peerId);
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

  static NativeRealtimeStateChangedEvent _decodeRealtimeState(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var realtimeId = '';
    var peerId = '';
    var state = 0;
    var revision = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          state = reader.varint(field.wireType);
        case 4:
          revision = reader.varint(field.wireType);
        case 5:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedRealtimeId(realtimeId);
    _validateDecodedPeerId(peerId);
    return NativeRealtimeStateChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      state: NativeRealtimeSessionState.fromWire(state),
      revision: revision,
      error: error,
    );
  }

  static NativeRealtimeSignalEvent _decodeRealtimeSignal(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var realtimeId = '';
    var peerId = '';
    var kind = 0;
    var revision = 0;
    var payload = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          kind = reader.varint(field.wireType);
        case 4:
          revision = reader.varint(field.wireType);
        case 5:
          payload = reader.bytes(field.wireType, _maxRealtimePayloadBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedRealtimeId(realtimeId);
    _validateDecodedPeerId(peerId);
    try {
      _validateSignalPayload(NativeRealtimeSignalKind.fromWire(kind), payload);
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
    if (revision <= 0) {
      throw const FormatException('Realtime signal revision must be positive.');
    }
    return NativeRealtimeSignalEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      kind: NativeRealtimeSignalKind.fromWire(kind),
      revision: revision,
      payload: payload,
    );
  }

  static NativeRealtimeSnapshotEvent _decodeRealtimeSnapshot(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var realtimeId = '';
    var peerId = '';
    var state = 0;
    var revision = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          state = reader.varint(field.wireType);
        case 4:
          revision = reader.varint(field.wireType);
        case 5:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedRealtimeId(realtimeId);
    _validateDecodedPeerId(peerId);
    return NativeRealtimeSnapshotEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      state: NativeRealtimeSessionState.fromWire(state),
      revision: revision,
      error: error,
    );
  }

  static NativeStreamHandle _decodeStreamHandle(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var openerDeviceId = '';
    var streamId = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          openerDeviceId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          streamId = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedPeerId(openerDeviceId);
    if (streamId < 1 || streamId > _maxStreamId) {
      throw const FormatException('SSH stream ID is outside bounds.');
    }
    return NativeStreamHandle(
      openerDeviceId: openerDeviceId,
      streamId: streamId,
    );
  }

  static NativeSshStreamDataReceivedEvent _decodeSshStreamData(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    NativeStreamHandle? handle;
    var data = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          handle = _decodeStreamHandle(
            reader.bytes(field.wireType, _maxStreamHandleBytes),
          );
        case 3:
          data = reader.bytes(field.wireType, _maxStreamDataBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedPeerId(peerId);
    final streamHandle = handle;
    if (streamHandle == null) {
      throw const FormatException('SSH stream event has no stream handle.');
    }
    return NativeSshStreamDataReceivedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      handle: streamHandle,
      data: data,
    );
  }

  static NativeSshStreamClosedEvent _decodeSshStreamClosed(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    NativeStreamHandle? handle;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          handle = _decodeStreamHandle(
            reader.bytes(field.wireType, _maxStreamHandleBytes),
          );
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedPeerId(peerId);
    final streamHandle = handle;
    if (streamHandle == null) {
      throw const FormatException('SSH stream event has no stream handle.');
    }
    return NativeSshStreamClosedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      handle: streamHandle,
    );
  }

  static NativeNetworkError _decodeError(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var code = 0;
    var message = '';
    String? operation;
    String? peerId;
    var retryDisposition = NativeRetryDisposition.unspecified;
    var retryAfterSeconds = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          code = reader.varint(field.wireType);
        case 2:
          message = reader.string(field.wireType, _maxErrorMessageBytes);
        case 3:
          operation = reader.string(field.wireType, _maxCommandIdBytes);
        case 4:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 5:
          retryDisposition = NativeRetryDisposition.fromWire(
            reader.varint(field.wireType),
          );
        case 6:
          retryAfterSeconds = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return NativeNetworkError(
      code: code,
      message: message,
      operation: operation?.isEmpty == true ? null : operation,
      peerId: peerId?.isEmpty == true ? null : peerId,
      retryDisposition: retryDisposition,
      retryAfterSeconds: retryAfterSeconds,
    );
  }

  static void _validateCommandId(String value) {
    if (value.isEmpty || _utf8ByteLength(value) > _maxCommandIdBytes) {
      throw ArgumentError.value(
        value,
        'commandId',
        'Must contain 1-128 bytes.',
      );
    }
  }

  static void _validateIdentifier(String value, String name, int maxBytes) {
    if (value.isEmpty || _utf8ByteLength(value) > maxBytes) {
      throw ArgumentError.value(
        value,
        name,
        '$name must contain 1-$maxBytes bytes.',
      );
    }
  }

  static void _validatePeerId(String value) {
    if (value.isEmpty || _utf8ByteLength(value) > _maxPeerIdBytes) {
      throw ArgumentError.value(value, 'peerId', 'Must contain 1-128 bytes.');
    }
  }

  static void _validateStreamId(int value) {
    if (value < 1 || value > _maxStreamId) {
      throw ArgumentError.value(
        value,
        'streamId',
        'Must be within 1-$_maxStreamId.',
      );
    }
  }

  static void _validateStreamHandle(NativeStreamHandle handle) {
    _validatePeerId(handle.openerDeviceId);
    _validateStreamId(handle.streamId);
  }

  static Uint8List _encodeStreamHandle(NativeStreamHandle handle) =>
      (_ProtoWriter()
            ..string(1, handle.openerDeviceId)
            ..varint(2, handle.streamId))
          .takeBytes();

  static void _validateStreamService(String value) {
    if (value.isEmpty || _utf8ByteLength(value) > _maxStreamServiceBytes) {
      throw ArgumentError.value(
        value,
        'service',
        'Must contain 1-$_maxStreamServiceBytes bytes.',
      );
    }
  }

  static void _validateRealtimeId(String value) {
    if (value.length != _realtimeIdBytes ||
        value != value.toLowerCase() ||
        !_isLowerHex(value)) {
      throw ArgumentError.value(
        value,
        'realtimeId',
        'Must be 32 lowercase hexadecimal characters.',
      );
    }
  }

  static void _validateDecodedRealtimeId(String value) {
    try {
      _validateRealtimeId(value);
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
  }

  static void _validateDecodedPeerId(String value) {
    if (value.isEmpty || _utf8ByteLength(value) > _maxPeerIdBytes) {
      throw const FormatException('Realtime peer ID is outside bounds.');
    }
  }

  static void _validateDecodedIdentifier(String value, String label) {
    if (value.isEmpty) {
      throw FormatException('$label is required.');
    }
  }

  static int _utf8ByteLength(String value) => utf8.encode(value).length;

  static bool _isLowerHex(String value) => value.codeUnits.every((code) {
    return (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66);
  });

  static void _validateSignalPayload(
    NativeRealtimeSignalKind kind,
    Uint8List payload,
  ) {
    if (kind == NativeRealtimeSignalKind.unspecified) {
      throw ArgumentError.value(kind, 'kind', 'Unknown signal kind.');
    }
    if (payload.length > _maxRealtimePayloadBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'Payload is too large.',
      );
    }
    if (kind == NativeRealtimeSignalKind.iceCandidate &&
        payload.length > _maxIceCandidateBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'ICE candidate payload is too large.',
      );
    }
    if (kind != NativeRealtimeSignalKind.webRtcClose &&
        kind != NativeRealtimeSignalKind.iceRestart &&
        kind != NativeRealtimeSignalKind.iceCandidate &&
        payload.isEmpty) {
      throw ArgumentError.value(
        payload,
        'payload',
        'Payload must not be empty.',
      );
    }
  }
}

final class _ProtoWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void varint(int fieldNumber, int value) {
    _writeVarint(fieldNumber << 3);
    _writeVarint(value);
  }

  void string(int fieldNumber, String value) =>
      message(fieldNumber, Uint8List.fromList(utf8.encode(value)));

  void bytesField(int fieldNumber, Uint8List value) =>
      message(fieldNumber, value);

  void message(int fieldNumber, Uint8List value) {
    _writeVarint((fieldNumber << 3) | 2);
    _writeVarint(value.length);
    _bytes.add(value);
  }

  void _writeVarint(int value) {
    var remaining = value;
    while (remaining >= 0x80) {
      _bytes.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.addByte(remaining);
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

final class _ProtoField {
  const _ProtoField(this.number, this.wireType);

  final int number;
  final int wireType;
}

final class _ProtoReader {
  _ProtoReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get isDone => _offset >= _bytes.length;

  _ProtoField field() {
    final key = _readVarint();
    if (key < 8) throw const FormatException('Invalid protobuf field key.');
    return _ProtoField(key >> 3, key & 7);
  }

  int varint(int wireType) {
    if (wireType != 0) throw const FormatException('Invalid varint wire type.');
    return _readVarint();
  }

  String string(int wireType, int maxBytes) =>
      utf8.decode(bytes(wireType, maxBytes));

  Uint8List bytes(int wireType, [int maxBytes = _maxEventBytes]) {
    if (wireType != 2) throw const FormatException('Invalid bytes wire type.');
    final length = _readVarint();
    if (length > maxBytes || length > _bytes.length - _offset) {
      throw const FormatException('Protobuf bytes are outside bounds.');
    }
    final value = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return Uint8List.fromList(value);
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        _readVarint();
      case 1:
        _advance(8);
      case 2:
        final length = _readVarint();
        _advance(length);
      case 5:
        _advance(4);
      default:
        throw const FormatException('Unsupported protobuf wire type.');
    }
  }

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_offset >= _bytes.length || shift > 63) {
        throw const FormatException('Truncated protobuf varint.');
      }
      final byte = _bytes[_offset++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
  }

  void _advance(int length) {
    if (length < 0 || length > _bytes.length - _offset) {
      throw const FormatException('Truncated protobuf field.');
    }
    _offset += length;
  }
}
