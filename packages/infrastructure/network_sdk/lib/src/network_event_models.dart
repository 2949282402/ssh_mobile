import 'network_configuration_models.dart';
import 'network_error_models.dart';
import 'network_route_models.dart';

/// Rust runtime 的统一 typed event。
sealed class SdkEvent {
  const SdkEvent({required this.eventId, required this.timestamp});

  final String eventId;
  final DateTime timestamp;
}

final class PeerStateChanged extends SdkEvent {
  const PeerStateChanged({
    required super.eventId,
    required super.timestamp,
    required this.peerId,
    required this.state,
    required this.routeType,
    this.routeTopology = NetworkRouteTopology.unspecified,
    this.routeTransport = NetworkRouteTransport.unspecified,
    this.error,
  });

  final String peerId;
  final PeerConnectionState state;
  final NetworkRouteType routeType;
  final NetworkRouteTopology routeTopology;
  final NetworkRouteTransport routeTransport;
  final NetworkError? error;
}

/// Peer-scoped causal route-attempt observation emitted by native connectivity.
final class RouteAttemptChanged extends SdkEvent {
  const RouteAttemptChanged({
    required super.eventId,
    required super.timestamp,
    required this.peerId,
    required this.attemptId,
    required this.phase,
    required this.routeType,
    this.commandId,
    this.error,
  });

  final String peerId;
  final String attemptId;
  final RouteAttemptPhase phase;
  final NetworkRouteType routeType;
  final String? commandId;
  final NetworkError? error;
}

final class TransferProgress extends SdkEvent {
  const TransferProgress({
    required super.eventId,
    required super.timestamp,
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

final class TransferCompleted extends SdkEvent {
  const TransferCompleted({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.localPath,
    this.peerId,
  });

  final String transferId;
  final String localPath;
  final String? peerId;
}

final class TransferFailed extends SdkEvent {
  const TransferFailed({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.error,
    this.peerId,
  });

  final String transferId;
  final NetworkError error;
  final String? peerId;
}

final class IncomingTransferOffer extends SdkEvent {
  const IncomingTransferOffer({
    required super.eventId,
    required super.timestamp,
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.fileSize,
    this.routeType = NetworkRouteType.unspecified,
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
  final NetworkRouteType routeType;
}

final class RouteChanged extends SdkEvent {
  const RouteChanged({
    required super.eventId,
    required super.timestamp,
    required this.snapshot,
  });

  final SdkRouteSnapshot snapshot;
}

final class RelayStateChanged extends SdkEvent {
  const RelayStateChanged({
    required super.eventId,
    required super.timestamp,
    required this.state,
    this.error,
  });

  final RelayConnectionState state;
  final NetworkError? error;
}

/// 单个对端的 Relay Presence 变化（online/updated/offline）。
final class PeerPresenceChanged extends SdkEvent {
  const PeerPresenceChanged({
    required super.eventId,
    required super.timestamp,
    required this.peerId,
    required this.generation,
    required this.state,
  });

  final String peerId;
  final int generation;
  final PeerPresenceState state;
}

/// Relay 认证连接后推送的完整在线设备快照。
final class PeerPresenceSnapshot extends SdkEvent {
  const PeerPresenceSnapshot({
    required super.eventId,
    required super.timestamp,
    required this.peers,
  });

  final List<PeerPresenceChanged> peers;
}
