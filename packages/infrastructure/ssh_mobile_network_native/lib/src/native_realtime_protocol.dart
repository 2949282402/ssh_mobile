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

/// Business lifecycle exposed by Network Protocol V2. This is intentionally
/// independent from carrier/session states.
enum NativePeerState {
  offline(0),
  connecting(1),
  online(2);

  const NativePeerState(this.wireValue);

  final int wireValue;

  static NativePeerState fromWire(int value) => NativePeerState.values
      .firstWhere((state) => state.wireValue == value, orElse: () => offline);
}

enum NativeE2eePolicy {
  required(0),
  disabled(1);

  const NativeE2eePolicy(this.wireValue);

  final int wireValue;
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

final class NativePeerConfig {
  NativePeerConfig({
    required this.peerId,
    required this.endpointAddress,
    required Uint8List identityPublicKey,
    required Uint8List e2ePublicKey,
    this.e2eePolicy = NativeE2eePolicy.required,
  }) : identityPublicKey = Uint8List.fromList(identityPublicKey),
       e2ePublicKey = Uint8List.fromList(e2ePublicKey);

  final String peerId;
  final String endpointAddress;
  final Uint8List identityPublicKey;
  final Uint8List e2ePublicKey;
  final NativeE2eePolicy e2eePolicy;
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

final class NativeCommandResultV2Event extends NativeNetworkEvent {
  const NativeCommandResultV2Event({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.commandId,
    required this.peerId,
    required this.state,
    this.error,
  });

  final String commandId;
  final String peerId;
  final int state;
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

final class NativePeerLifecycleEvent extends NativeNetworkEvent {
  const NativePeerLifecycleEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.state,
    required this.e2eePolicy,
    this.error,
  });

  final String peerId;
  final NativePeerState state;
  final NativeE2eePolicy e2eePolicy;
  final NativeNetworkError? error;
}

final class NativePeerDiagnosticsEvent extends NativeNetworkEvent {
  const NativePeerDiagnosticsEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.state,
    required this.e2eePolicy,
    required this.readyPathCount,
    required this.queuedCommandCount,
    required this.activeStreamCount,
    required this.activeTransferCount,
    this.lastError,
  });

  final String peerId;
  final NativePeerState state;
  final NativeE2eePolicy e2eePolicy;
  final int readyPathCount;
  final int queuedCommandCount;
  final int activeStreamCount;
  final int activeTransferCount;
  final NativeNetworkError? lastError;
}

final class NativeNetworkEnvironmentChangedEvent extends NativeNetworkEvent {
  const NativeNetworkEnvironmentChangedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.generation,
    required this.hasConnectivity,
    required this.isForeground,
    required this.isMetered,
  });

  final int generation;
  final bool hasConnectivity;
  final bool isForeground;
  final bool isMetered;
}

final class NativePeerTransferProgressEvent extends NativeNetworkEvent {
  const NativePeerTransferProgressEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.transferId,
    required this.confirmedOffset,
    required this.totalBytes,
    required this.paused,
  });

  final String peerId;
  final String transferId;
  final int confirmedOffset;
  final int totalBytes;
  final bool paused;
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
    final commandId = switch (event) {
      NativeCommandResultEvent() => event.commandId,
      NativeCommandResultV2Event() => event.commandId,
      _ => null,
    };
    if (commandId == null) return event;
    if (!_pendingCommandIds.remove(commandId)) return null;
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
/// Bounded Protobuf command/event facade for the native SDK API.
final class NativeNetworkProtocol {
  /// Current native protocol version.
  static const int protocolVersion = _protocolVersion;

  const NativeNetworkProtocol._();

  static Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
    int intent = 0,
    int communicationClass = 2,
  }) => _NativeProtocolCommandEncoder.connectPeerCommand(
    commandId: commandId,
    peerId: peerId,
    intent: intent,
    communicationClass: communicationClass,
  );

  static Uint8List disconnectPeerCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.disconnectPeerCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List sendMessageCommand({
    required String commandId,
    required String peerId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
  }) => _NativeProtocolCommandEncoder.sendMessageCommand(
    commandId: commandId,
    peerId: peerId,
    channelId: channelId,
    payload: payload,
    deliveryPolicy: deliveryPolicy,
  );

  static Uint8List sendMessageV2Command({
    required String commandId,
    required String peerId,
    required String messageId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
    NativeE2eePolicy e2eePolicy = NativeE2eePolicy.required,
  }) => _NativeProtocolCommandEncoder.sendMessageV2Command(
    commandId: commandId,
    peerId: peerId,
    messageId: messageId,
    channelId: channelId,
    payload: payload,
    deliveryPolicy: deliveryPolicy,
    e2eePolicy: e2eePolicy,
  );

  static Uint8List upsertPeerV2Command({
    required String commandId,
    required NativePeerConfig config,
  }) => _NativeProtocolCommandEncoder.upsertPeerV2Command(
    commandId: commandId,
    config: config,
  );

  static Uint8List removePeerCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.removePeerCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List transferCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
    int confirmedOffset = 0,
    bool resume = false,
  }) => _NativeProtocolCommandEncoder.transferCommand(
    commandId: commandId,
    peerId: peerId,
    transferId: transferId,
    filePath: filePath,
    confirmedOffset: confirmedOffset,
    resume: resume,
  );

  static Uint8List peerDiagnosticsCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.peerDiagnosticsCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List networkEnvironmentChangedCommand({
    required String commandId,
    required int generation,
    required bool hasConnectivity,
    required bool isForeground,
    required bool isMetered,
  }) => _NativeProtocolCommandEncoder.networkEnvironmentChangedCommand(
    commandId: commandId,
    generation: generation,
    hasConnectivity: hasConnectivity,
    isForeground: isForeground,
    isMetered: isMetered,
  );

  static Uint8List sendFileCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
  }) => _NativeProtocolCommandEncoder.sendFileCommand(
    commandId: commandId,
    peerId: peerId,
    transferId: transferId,
    filePath: filePath,
  );

  static Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) => _NativeProtocolCommandEncoder.cancelTransferCommand(
    commandId: commandId,
    transferId: transferId,
  );

  static Uint8List startRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.startRealtimeSessionCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
  );

  static Uint8List stopRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
  }) => _NativeProtocolCommandEncoder.stopRealtimeSessionCommand(
    commandId: commandId,
    realtimeId: realtimeId,
  );

  static Uint8List sendRealtimeSignalCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required NativeRealtimeSignalKind kind,
    required int revision,
    required Uint8List payload,
  }) => _NativeProtocolCommandEncoder.sendRealtimeSignalCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    kind: kind,
    revision: revision,
    payload: payload,
  );

  static Uint8List sshStreamOpenCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    String service = 'ssh',
  }) => _NativeProtocolCommandEncoder.sshStreamOpenCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    service: service,
  );

  static Uint8List sshStreamDataCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required Uint8List data,
  }) => _NativeProtocolCommandEncoder.sshStreamDataCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    data: data,
  );

  static Uint8List sshStreamCloseCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) => _NativeProtocolCommandEncoder.sshStreamCloseCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
  );

  static NativeNetworkEvent? decodeEvent(Uint8List bytes) =>
      _NativeProtocolEventDecoder.decodeEvent(bytes);
}

/// Owns bounded command validation, payload encoding, and V2 envelopes.
final class _NativeProtocolCommandEncoder {
  static const _values = _NativeProtocolValueMapper();

  /// Encodes a Peer connect request using the existing V2 command envelope.
  /// The v2 adapter supplies the business requirement, not a concrete socket.
  static Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
    int intent = 0,
    int communicationClass = 2,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
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
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
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
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    if (channelId.isEmpty ||
        _values.utf8ByteLength(channelId) > _maxChannelIdBytes) {
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

  /// Encodes the frozen peer-scoped message command (tag 30). The identity is
  /// `(peerId, messageId)` and never depends on a Session or route.
  static Uint8List sendMessageV2Command({
    required String commandId,
    required String peerId,
    required String messageId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
    NativeE2eePolicy e2eePolicy = NativeE2eePolicy.required,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateIdentifier(messageId, 'messageId', _maxMessageIdBytes);
    _values.validateIdentifier(channelId, 'channelId', _maxChannelIdBytes);
    if (payload.length > _maxEventBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'Payload is too large.',
      );
    }
    return _command(
      commandId,
      30,
      (_ProtoWriter()
            ..string(1, peerId)
            ..string(2, messageId)
            ..string(3, channelId)
            ..bytesField(4, payload)
            ..varint(5, deliveryPolicy)
            ..varint(6, e2eePolicy.wireValue))
          .takeBytes(),
    );
  }

  static Uint8List upsertPeerV2Command({
    required String commandId,
    required NativePeerConfig config,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(config.peerId);
    _values.validateIdentifier(
      config.endpointAddress,
      'endpointAddress',
      _maxEventIdBytes,
    );
    return _command(
      commandId,
      28,
      (_ProtoWriter()..message(
            1,
            (_ProtoWriter()
                  ..string(1, config.peerId)
                  ..string(2, config.endpointAddress)
                  ..bytesField(3, config.identityPublicKey)
                  ..bytesField(4, config.e2ePublicKey)
                  ..varint(5, config.e2eePolicy.wireValue))
                .takeBytes(),
          ))
          .takeBytes(),
    );
  }

  static Uint8List removePeerCommand({
    required String commandId,
    required String peerId,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    return _command(
      commandId,
      29,
      (_ProtoWriter()..string(1, peerId)).takeBytes(),
    );
  }

  static Uint8List transferCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
    int confirmedOffset = 0,
    bool resume = false,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateIdentifier(transferId, 'transferId', _maxTransferIdBytes);
    _values.validateIdentifier(filePath, 'filePath', _maxEventBytes);
    if (confirmedOffset < 0) {
      throw ArgumentError.value(confirmedOffset, 'confirmedOffset');
    }
    return _command(
      commandId,
      31,
      (_ProtoWriter()
            ..string(1, peerId)
            ..string(2, transferId)
            ..string(3, filePath)
            ..varint(4, confirmedOffset)
            ..varint(5, resume ? 1 : 0))
          .takeBytes(),
    );
  }

  static Uint8List peerDiagnosticsCommand({
    required String commandId,
    required String peerId,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    return _command(
      commandId,
      32,
      (_ProtoWriter()..string(1, peerId)).takeBytes(),
    );
  }

  static Uint8List networkEnvironmentChangedCommand({
    required String commandId,
    required int generation,
    required bool hasConnectivity,
    required bool isForeground,
    required bool isMetered,
  }) {
    _values.validateCommandId(commandId);
    if (generation < 0) throw ArgumentError.value(generation, 'generation');
    return _command(
      commandId,
      33,
      (_ProtoWriter()
            ..varint(1, generation)
            ..varint(2, hasConnectivity ? 1 : 0)
            ..varint(3, isForeground ? 1 : 0)
            ..varint(4, isMetered ? 1 : 0))
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
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateIdentifier(transferId, 'transferId', _maxTransferIdBytes);
    _values.validateIdentifier(filePath, 'filePath', _maxEventBytes);
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
    _values.validateCommandId(commandId);
    _values.validateIdentifier(transferId, 'transferId', _maxTransferIdBytes);
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
    _values.validateCommandId(commandId);
    _values.validateRealtimeId(realtimeId);
    _values.validatePeerId(peerId);
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
    _values.validateCommandId(commandId);
    _values.validateRealtimeId(realtimeId);
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
    _values.validateCommandId(commandId);
    _values.validateRealtimeId(realtimeId);
    _values.validatePeerId(peerId);
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
    _values.validateSignalPayload(kind, payload);
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
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateStreamHandle(handle);
    _values.validateStreamService(service);
    return _command(
      commandId,
      25,
      (_ProtoWriter()
            ..string(1, peerId)
            ..message(2, _values.encodeStreamHandle(handle))
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
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateStreamHandle(handle);
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
            ..message(2, _values.encodeStreamHandle(handle))
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
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateStreamHandle(handle);
    return _command(
      commandId,
      27,
      (_ProtoWriter()
            ..string(1, peerId)
            ..message(2, _values.encodeStreamHandle(handle)))
          .takeBytes(),
    );
  }

  static Uint8List _command(String commandId, int field, Uint8List payload) =>
      (_ProtoWriter()
            ..string(1, commandId)
            ..varint(2, _protocolVersion)
            ..message(field, payload))
          .takeBytes();
}

/// Owns event envelope dispatch and typed FFI value construction.
final class _NativeProtocolEventDecoder {
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
        case 28:
        case 29:
        case 30:
        case 31:
        case 32:
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
      10 => _NativePeerEventDecoder._decodePeerState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      11 => _NativeDeliveryEventDecoder._decodeTransferProgress(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      13 => _NativeDeliveryEventDecoder._decodeCommandResult(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      14 => _NativeDeliveryEventDecoder._decodeIncomingTransferOffer(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      15 => _NativeDeliveryEventDecoder._decodeTransferCompleted(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      16 => _NativeDeliveryEventDecoder._decodeTransferFailed(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      18 => _NativePeerEventDecoder._decodeRelayState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      19 => _NativeDeliveryEventDecoder._decodeChannelMessage(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      20 => _NativeDeliveryEventDecoder._decodeDeliveryAcked(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      21 => _NativeRealtimeEventDecoder._decodeRealtimeState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      24 => _NativePeerEventDecoder._decodePresenceChanged(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      25 => _NativePeerEventDecoder._decodePresenceSnapshot(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      22 => _NativeRealtimeEventDecoder._decodeRealtimeSignal(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      23 => _NativeRealtimeEventDecoder._decodeRealtimeSnapshot(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      26 => _NativeRealtimeEventDecoder._decodeSshStreamData(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      27 => _NativeRealtimeEventDecoder._decodeSshStreamClosed(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      28 => _NativePeerEventDecoder._decodePeerLifecycle(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      29 => _NativeDeliveryEventDecoder._decodeCommandResultV2(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      30 => _NativePeerEventDecoder._decodePeerDiagnostics(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      31 => _NativePeerEventDecoder._decodeEnvironmentChanged(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      32 => _NativePeerEventDecoder._decodePeerTransferProgress(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      _ => null,
    };
  }
}

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

/// Owns command-result, Delivery, and Transfer event mapping.
final class _NativeDeliveryEventDecoder {
  static const _values = _NativeProtocolValueMapper();

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
          error = _values.decodeError(reader.bytes(field.wireType));
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

  static NativeCommandResultV2Event _decodeCommandResultV2(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var commandId = '';
    var peerId = '';
    var state = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          commandId = reader.string(field.wireType, _maxCommandIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          state = reader.varint(field.wireType);
        case 4:
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    if (commandId.isEmpty) {
      throw const FormatException(
        'Native V2 command result has no command ID.',
      );
    }
    return NativeCommandResultV2Event(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      commandId: commandId,
      peerId: peerId,
      state: state,
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
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
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
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
    _values.validateDecodedPeerId(peerId);
    _values.validateDecodedIdentifier(fileName, 'file name');
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
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
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
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
    return NativeTransferFailedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
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
    _values.validateDecodedPeerId(peerId);
    _values.validateDecodedIdentifier(sessionId, 'session ID');
    _values.validateDecodedIdentifier(channelId, 'channel ID');
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
    _values.validateDecodedPeerId(peerId);
    _values.validateDecodedIdentifier(sessionId, 'session ID');
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
}

/// Owns Realtime and SSH ReliableStream event mapping.
final class _NativeRealtimeEventDecoder {
  static const _values = _NativeProtocolValueMapper();

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
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedRealtimeId(realtimeId);
    _values.validateDecodedPeerId(peerId);
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
    _values.validateDecodedRealtimeId(realtimeId);
    _values.validateDecodedPeerId(peerId);
    try {
      _values.validateSignalPayload(
        NativeRealtimeSignalKind.fromWire(kind),
        payload,
      );
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
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedRealtimeId(realtimeId);
    _values.validateDecodedPeerId(peerId);
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
    _values.validateDecodedPeerId(openerDeviceId);
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
    _values.validateDecodedPeerId(peerId);
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
    _values.validateDecodedPeerId(peerId);
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
}

final class _NativeProtocolValueMapper {
  const _NativeProtocolValueMapper();

  void validateCommandId(String value) {
    if (value.isEmpty || utf8ByteLength(value) > _maxCommandIdBytes) {
      throw ArgumentError.value(
        value,
        'commandId',
        'Must contain 1-128 bytes.',
      );
    }
  }

  void validateIdentifier(String value, String name, int maxBytes) {
    if (value.isEmpty || utf8ByteLength(value) > maxBytes) {
      throw ArgumentError.value(
        value,
        name,
        '$name must contain 1-$maxBytes bytes.',
      );
    }
  }

  void validatePeerId(String value) {
    if (value.isEmpty || utf8ByteLength(value) > _maxPeerIdBytes) {
      throw ArgumentError.value(value, 'peerId', 'Must contain 1-128 bytes.');
    }
  }

  void validateStreamId(int value) {
    if (value < 1 || value > _maxStreamId) {
      throw ArgumentError.value(
        value,
        'streamId',
        'Must be within 1-$_maxStreamId.',
      );
    }
  }

  void validateStreamHandle(NativeStreamHandle handle) {
    validatePeerId(handle.openerDeviceId);
    validateStreamId(handle.streamId);
  }

  Uint8List encodeStreamHandle(NativeStreamHandle handle) =>
      (_ProtoWriter()
            ..string(1, handle.openerDeviceId)
            ..varint(2, handle.streamId))
          .takeBytes();

  void validateStreamService(String value) {
    if (value.isEmpty || utf8ByteLength(value) > _maxStreamServiceBytes) {
      throw ArgumentError.value(
        value,
        'service',
        'Must contain 1-$_maxStreamServiceBytes bytes.',
      );
    }
  }

  void validateRealtimeId(String value) {
    if (value.length != _realtimeIdBytes ||
        value != value.toLowerCase() ||
        !isLowerHex(value)) {
      throw ArgumentError.value(
        value,
        'realtimeId',
        'Must be 32 lowercase hexadecimal characters.',
      );
    }
  }

  void validateDecodedRealtimeId(String value) {
    try {
      validateRealtimeId(value);
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
  }

  void validateDecodedPeerId(String value) {
    if (value.isEmpty || utf8ByteLength(value) > _maxPeerIdBytes) {
      throw const FormatException('Realtime peer ID is outside bounds.');
    }
  }

  void validateDecodedIdentifier(String value, String label) {
    if (value.isEmpty) {
      throw FormatException('$label is required.');
    }
  }

  int utf8ByteLength(String value) => utf8.encode(value).length;

  bool isLowerHex(String value) => value.codeUnits.every((code) {
    return (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66);
  });

  void validateSignalPayload(NativeRealtimeSignalKind kind, Uint8List payload) {
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

  NativeNetworkError decodeError(Uint8List bytes) {
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
