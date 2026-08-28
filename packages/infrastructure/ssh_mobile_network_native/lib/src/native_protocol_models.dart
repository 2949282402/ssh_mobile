part of 'native_realtime_protocol.dart';

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
    this.allowDirect = true,
    this.allowRelay = false,
  }) : identityPublicKey = Uint8List.fromList(identityPublicKey),
       e2ePublicKey = Uint8List.fromList(e2ePublicKey);

  final String peerId;
  final String endpointAddress;
  final Uint8List identityPublicKey;
  final Uint8List e2ePublicKey;
  final NativeE2eePolicy e2eePolicy;
  final bool allowDirect;
  final bool allowRelay;
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

/// Peer-scoped causal route-attempt observation emitted by native connectivity.
final class NativeRouteAttemptChangedEvent extends NativeNetworkEvent {
  const NativeRouteAttemptChangedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.peerId,
    required this.attemptId,
    required this.phase,
    required this.routeType,
    this.commandId,
    this.error,
  });

  final String peerId;
  final String attemptId;
  final NativeRouteAttemptPhase phase;
  final NativeRouteType routeType;
  final String? commandId;
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
