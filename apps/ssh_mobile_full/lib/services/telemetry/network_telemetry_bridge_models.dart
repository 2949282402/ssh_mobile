part of 'network_telemetry_bridge.dart';

final class _BridgePeerContext {
  _BridgePeerContext({required this.traceId, required this.touchedAt});

  final String traceId;
  DateTime touchedAt;
}

final class _BridgeAttemptContext {
  _BridgeAttemptContext({
    required this.peerId,
    required this.traceId,
    required this.touchedAt,
  });

  final String peerId;
  final String traceId;
  DateTime touchedAt;
}

final class _PendingDirectFailure {
  _PendingDirectFailure({
    required this.peerId,
    required this.traceId,
    required this.attemptId,
    required this.error,
    required this.touchedAt,
  });

  final String peerId;
  final String traceId;
  final String attemptId;
  final NetworkError? error;
  final DateTime touchedAt;
}
