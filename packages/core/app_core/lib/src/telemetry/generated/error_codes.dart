// GENERATED DO NOT EDIT, regenerate via dart run tool/gen_telemetry_contract.dart
// ignore_for_file: type=lint
//
/// Compile-time error-code catalog constants generated from
/// `contracts/telemetry/error_codes.yaml`. Pure data, no logic.
///
import '../telemetry_catalog.dart';

class TelemetryErrorCodes {
  const TelemetryErrorCodes._();

  static const netQuicConnRefused = TelemetryErrorCodeDefinition(
    code: 'NET_QUIC_CONN_REFUSED',
    category: 'network',
    terminalFailure: false,
  );

  static const netQuicTimeout = TelemetryErrorCodeDefinition(
    code: 'NET_QUIC_TIMEOUT',
    category: 'network',
    terminalFailure: false,
  );

  static const netRelayUnavailable = TelemetryErrorCodeDefinition(
    code: 'NET_RELAY_UNAVAILABLE',
    category: 'network',
    terminalFailure: true,
  );

  static const sshAuthFailed = TelemetryErrorCodeDefinition(
    code: 'SSH_AUTH_FAILED',
    category: 'ssh',
    terminalFailure: true,
  );

  static const sshHostKeyMismatch = TelemetryErrorCodeDefinition(
    code: 'SSH_HOST_KEY_MISMATCH',
    category: 'ssh',
    terminalFailure: true,
  );

  static const sshTimeout = TelemetryErrorCodeDefinition(
    code: 'SSH_TIMEOUT',
    category: 'ssh',
    terminalFailure: true,
  );

  static const sftpPermissionDenied = TelemetryErrorCodeDefinition(
    code: 'SFTP_PERMISSION_DENIED',
    category: 'sftp',
    terminalFailure: true,
  );

  static const sftpFileNotFound = TelemetryErrorCodeDefinition(
    code: 'SFTP_FILE_NOT_FOUND',
    category: 'sftp',
    terminalFailure: true,
  );

  static const sftpTransferAborted = TelemetryErrorCodeDefinition(
    code: 'SFTP_TRANSFER_ABORTED',
    category: 'sftp',
    terminalFailure: true,
  );

  static const lanPeerDisconnected = TelemetryErrorCodeDefinition(
    code: 'LAN_PEER_DISCONNECTED',
    category: 'lan',
    terminalFailure: false,
  );

  static const lanHandshakeFailed = TelemetryErrorCodeDefinition(
    code: 'LAN_HANDSHAKE_FAILED',
    category: 'lan',
    terminalFailure: true,
  );

  static const aiRateLimited = TelemetryErrorCodeDefinition(
    code: 'AI_RATE_LIMITED',
    category: 'ai',
    terminalFailure: false,
  );

  static const aiServiceUnavailable = TelemetryErrorCodeDefinition(
    code: 'AI_SERVICE_UNAVAILABLE',
    category: 'ai',
    terminalFailure: true,
  );

  static const telemetryAuthFailed = TelemetryErrorCodeDefinition(
    code: 'TELEMETRY_AUTH_FAILED',
    category: 'telemetry',
    terminalFailure: true,
  );

  static const telemetryNetworkError = TelemetryErrorCodeDefinition(
    code: 'TELEMETRY_NETWORK_ERROR',
    category: 'telemetry',
    terminalFailure: false,
  );

  static const telemetryStorageFull = TelemetryErrorCodeDefinition(
    code: 'TELEMETRY_STORAGE_FULL',
    category: 'telemetry',
    terminalFailure: false,
  );

}
