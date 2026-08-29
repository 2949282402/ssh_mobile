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
    description:
        'Direct QUIC connection refused by peer or relay; fallback may proceed.',
  );

  static const netQuicTimeout = TelemetryErrorCodeDefinition(
    code: 'NET_QUIC_TIMEOUT',
    category: 'network',
    terminalFailure: false,
    description: 'Direct QUIC connection handshake timed out.',
  );

  static const netQuicFailed = TelemetryErrorCodeDefinition(
    code: 'NET_QUIC_FAILED',
    category: 'network',
    terminalFailure: false,
    description:
        'Direct QUIC connection failed for an unclassified reason; fallback may proceed.',
  );

  static const netRelayUnavailable = TelemetryErrorCodeDefinition(
    code: 'NET_RELAY_UNAVAILABLE',
    category: 'network',
    terminalFailure: true,
    description:
        'Relay server is unreachable or returned a service unavailable error.',
  );

  static const sshAuthFailed = TelemetryErrorCodeDefinition(
    code: 'SSH_AUTH_FAILED',
    category: 'ssh',
    terminalFailure: true,
    description:
        'SSH password, public key, or interactive authentication failed.',
  );

  static const sshHostKeyMismatch = TelemetryErrorCodeDefinition(
    code: 'SSH_HOST_KEY_MISMATCH',
    category: 'ssh',
    terminalFailure: true,
    description:
        'Remote host key verification failed or did not match known hosts.',
  );

  static const sshTimeout = TelemetryErrorCodeDefinition(
    code: 'SSH_TIMEOUT',
    category: 'ssh',
    terminalFailure: true,
    description: 'SSH connection or banner exchange timed out.',
  );

  static const sshConnectFailed = TelemetryErrorCodeDefinition(
    code: 'SSH_CONNECT_FAILED',
    category: 'ssh',
    terminalFailure: true,
    description:
        'SSH connection failed for a reason not covered by a more specific code.',
  );

  static const sftpPermissionDenied = TelemetryErrorCodeDefinition(
    code: 'SFTP_PERMISSION_DENIED',
    category: 'sftp',
    terminalFailure: true,
    description:
        'Remote filesystem operation denied due to lack of permissions.',
  );

  static const sftpFileNotFound = TelemetryErrorCodeDefinition(
    code: 'SFTP_FILE_NOT_FOUND',
    category: 'sftp',
    terminalFailure: true,
    description: 'Remote target file or directory does not exist.',
  );

  static const sftpTransferAborted = TelemetryErrorCodeDefinition(
    code: 'SFTP_TRANSFER_ABORTED',
    category: 'sftp',
    terminalFailure: true,
    description: 'SFTP file transfer was aborted by user or connection drop.',
  );

  static const sftpQuotaExceeded = TelemetryErrorCodeDefinition(
    code: 'SFTP_QUOTA_EXCEEDED',
    category: 'sftp',
    terminalFailure: true,
    description: 'Remote filesystem quota or available space was exhausted.',
  );

  static const sftpOperationFailed = TelemetryErrorCodeDefinition(
    code: 'SFTP_OPERATION_FAILED',
    category: 'sftp',
    terminalFailure: true,
    description: 'SFTP operation failed for an unclassified reason.',
  );

  static const lanPeerDisconnected = TelemetryErrorCodeDefinition(
    code: 'LAN_PEER_DISCONNECTED',
    category: 'lan',
    terminalFailure: false,
    description: 'LAN peer disconnected during discovery or session.',
  );

  static const lanHandshakeFailed = TelemetryErrorCodeDefinition(
    code: 'LAN_HANDSHAKE_FAILED',
    category: 'lan',
    terminalFailure: true,
    description: 'LAN encryption or pairing handshake failed.',
  );

  static const aiRateLimited = TelemetryErrorCodeDefinition(
    code: 'AI_RATE_LIMITED',
    category: 'ai',
    terminalFailure: false,
    description: 'AI provider rate limit reached; retryable.',
  );

  static const aiServiceUnavailable = TelemetryErrorCodeDefinition(
    code: 'AI_SERVICE_UNAVAILABLE',
    category: 'ai',
    terminalFailure: true,
    description: 'AI provider service unavailable or invalid API key.',
  );

  static const appUncaughtError = TelemetryErrorCodeDefinition(
    code: 'APP_UNCAUGHT_ERROR',
    category: 'app',
    terminalFailure: false,
    description:
        'An uncaught application error was captured without a confirmed fatal crash.',
  );

  static const appFatalError = TelemetryErrorCodeDefinition(
    code: 'APP_FATAL_ERROR',
    category: 'app',
    terminalFailure: true,
    description: 'A fatal application error or crash was captured.',
  );

  static const telemetryAuthFailed = TelemetryErrorCodeDefinition(
    code: 'TELEMETRY_AUTH_FAILED',
    category: 'telemetry',
    terminalFailure: true,
    description: 'Device authentication to telemetry endpoint failed.',
  );

  static const telemetryNetworkError = TelemetryErrorCodeDefinition(
    code: 'TELEMETRY_NETWORK_ERROR',
    category: 'telemetry',
    terminalFailure: false,
    description: 'Transient network failure during telemetry upload.',
  );

  static const telemetryStorageFull = TelemetryErrorCodeDefinition(
    code: 'TELEMETRY_STORAGE_FULL',
    category: 'telemetry',
    terminalFailure: false,
    description: 'Local storage limit reached; overflow state exposed.',
  );

  static const List<TelemetryErrorCodeDefinition> all =
      <TelemetryErrorCodeDefinition>[
        netQuicConnRefused,
        netQuicTimeout,
        netQuicFailed,
        netRelayUnavailable,
        sshAuthFailed,
        sshHostKeyMismatch,
        sshTimeout,
        sshConnectFailed,
        sftpPermissionDenied,
        sftpFileNotFound,
        sftpTransferAborted,
        sftpQuotaExceeded,
        sftpOperationFailed,
        lanPeerDisconnected,
        lanHandshakeFailed,
        aiRateLimited,
        aiServiceUnavailable,
        appUncaughtError,
        appFatalError,
        telemetryAuthFailed,
        telemetryNetworkError,
        telemetryStorageFull,
      ];
}
