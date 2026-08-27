// GENERATED DO NOT EDIT, regenerate via dart run tool/gen_telemetry_contract.dart
// ignore_for_file: type=lint
//
/// Compile-time event catalog constants generated from
/// `contracts/telemetry/events.yaml`. Pure data, no logic.
///
import '../telemetry_model.dart';
import '../telemetry_catalog.dart';

class TelemetryEvents {
  const TelemetryEvents._();

  static const appLifecycleStarted = TelemetryEventDefinition(
    name: 'app.lifecycle.started',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'app',
    severity: TelemetrySeverity.info,
    operationGroup: 'app.lifecycle',
    operationRole: 'started',
    description:
        'Emitted when the application process completes bootstrap and starts.',
    allowedProperties: {'cold_start', 'start_type'},
    requiredProperties: {},
    propertyTypes: {'cold_start': 'boolean', 'start_type': 'string'},
  );

  static const appLifecycleBackgrounded = TelemetryEventDefinition(
    name: 'app.lifecycle.backgrounded',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'app',
    severity: TelemetrySeverity.info,
    operationGroup: 'app.lifecycle',
    operationRole: 'state_change',
    description: 'Emitted when the application transitions to the background.',
    allowedProperties: {'active_sessions'},
    requiredProperties: {},
    propertyTypes: {'active_sessions': 'integer'},
  );

  static const appLifecycleForegrounded = TelemetryEventDefinition(
    name: 'app.lifecycle.foregrounded',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'app',
    severity: TelemetrySeverity.info,
    operationGroup: 'app.lifecycle',
    operationRole: 'state_change',
    description: 'Emitted when the application returns to the foreground.',
    allowedProperties: {'background_duration_ms'},
    requiredProperties: {},
    propertyTypes: {'background_duration_ms': 'integer'},
  );

  static const networkQuicConnected = TelemetryEventDefinition(
    name: 'network.quic.connected',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'network',
    severity: TelemetrySeverity.info,
    operationGroup: 'network.quic',
    operationRole: 'success',
    description: 'Emitted when a direct QUIC network path is established.',
    allowedProperties: {'protocol_version', 'rtt_ms'},
    requiredProperties: {},
    propertyTypes: {'protocol_version': 'string', 'rtt_ms': 'integer'},
  );

  static const networkQuicFailed = TelemetryEventDefinition(
    name: 'network.quic.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'network',
    severity: TelemetrySeverity.warn,
    operationGroup: 'network.quic',
    operationRole: 'failure',
    description: 'Emitted when QUIC connection attempt fails.',
    allowedProperties: {'fallback_used', 'reason'},
    requiredProperties: {},
    propertyTypes: {'fallback_used': 'boolean', 'reason': 'string'},
  );

  static const networkRelayConnected = TelemetryEventDefinition(
    name: 'network.relay.connected',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'network',
    severity: TelemetrySeverity.info,
    operationGroup: 'network.relay',
    operationRole: 'success',
    description: 'Emitted when connected to the Relay control or data plane.',
    allowedProperties: {'relay_region'},
    requiredProperties: {},
    propertyTypes: {'relay_region': 'string'},
  );

  static const networkRelayFallback = TelemetryEventDefinition(
    name: 'network.relay.fallback',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'network',
    severity: TelemetrySeverity.warn,
    operationGroup: 'network.relay',
    operationRole: 'fallback',
    description:
        'Emitted when connection falls back from direct path to Relay.',
    allowedProperties: {'direct_error'},
    requiredProperties: {},
    propertyTypes: {'direct_error': 'string'},
  );

  static const networkRelayFailed = TelemetryEventDefinition(
    name: 'network.relay.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'network',
    severity: TelemetrySeverity.error,
    operationGroup: 'network.relay',
    operationRole: 'failure',
    description: 'Emitted when a Relay connection attempt fails.',
    allowedProperties: {'fallback_used', 'reason'},
    requiredProperties: {},
    propertyTypes: {'fallback_used': 'boolean', 'reason': 'string'},
  );

  static const sshSessionStarted = TelemetryEventDefinition(
    name: 'ssh.session.started',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    operationGroup: 'ssh.session',
    operationRole: 'started',
    description:
        'Emitted when an SSH interactive terminal or command session starts.',
    allowedProperties: {'auth_method', 'session_type'},
    requiredProperties: {},
    propertyTypes: {'auth_method': 'string', 'session_type': 'string'},
  );

  static const sshSessionTerminated = TelemetryEventDefinition(
    name: 'ssh.session.terminated',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    operationGroup: 'ssh.session',
    operationRole: 'success',
    description: 'Emitted when an SSH session closes normally.',
    allowedProperties: {'duration_ms', 'exit_code'},
    requiredProperties: {},
    propertyTypes: {'duration_ms': 'integer', 'exit_code': 'integer'},
  );

  static const sshSessionFailed = TelemetryEventDefinition(
    name: 'ssh.session.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'ssh',
    severity: TelemetrySeverity.error,
    operationGroup: 'ssh.session',
    operationRole: 'failure',
    description: 'Emitted when an SSH connection or authentication fails.',
    allowedProperties: {'retry_count', 'stage'},
    requiredProperties: {},
    propertyTypes: {'retry_count': 'integer', 'stage': 'string'},
  );

  static const sshSessionConnected = TelemetryEventDefinition(
    name: 'ssh.session.connected',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    operationGroup: 'ssh.session',
    operationRole: 'success',
    description: 'Emitted when an SSH session connection is established.',
    allowedProperties: {'session_type'},
    requiredProperties: {},
    propertyTypes: {'session_type': 'string'},
  );

  static const sftpTransferStarted = TelemetryEventDefinition(
    name: 'sftp.transfer.started',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'sftp',
    severity: TelemetrySeverity.info,
    operationGroup: 'sftp.transfer',
    operationRole: 'started',
    description: 'Emitted when an SFTP file upload or download begins.',
    allowedProperties: {'direction', 'file_size_bytes'},
    requiredProperties: {'direction'},
    propertyTypes: {'direction': 'string', 'file_size_bytes': 'integer'},
  );

  static const sftpTransferCompleted = TelemetryEventDefinition(
    name: 'sftp.transfer.completed',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'sftp',
    severity: TelemetrySeverity.info,
    operationGroup: 'sftp.transfer',
    operationRole: 'success',
    description: 'Emitted when an SFTP file transfer completes successfully.',
    allowedProperties: {'bytes_transferred', 'direction', 'duration_ms'},
    requiredProperties: {'bytes_transferred', 'direction'},
    propertyTypes: {
      'bytes_transferred': 'integer',
      'direction': 'string',
      'duration_ms': 'integer',
    },
  );

  static const sftpTransferFailed = TelemetryEventDefinition(
    name: 'sftp.transfer.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'sftp',
    severity: TelemetrySeverity.error,
    operationGroup: 'sftp.transfer',
    operationRole: 'failure',
    description: 'Emitted when an SFTP transfer fails.',
    allowedProperties: {'bytes_transferred', 'direction', 'stage'},
    requiredProperties: {'direction'},
    propertyTypes: {
      'bytes_transferred': 'integer',
      'direction': 'string',
      'stage': 'string',
    },
  );

  static const lanDiscoveryPeerFound = TelemetryEventDefinition(
    name: 'lan.discovery.peer_found',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'lan_share',
    severity: TelemetrySeverity.info,
    operationGroup: 'lan.discovery',
    operationRole: 'success',
    description: 'Emitted when a LAN peer is discovered.',
    allowedProperties: {'peer_count'},
    requiredProperties: {},
    propertyTypes: {'peer_count': 'integer'},
  );

  static const lanTransferCompleted = TelemetryEventDefinition(
    name: 'lan.transfer.completed',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'lan_share',
    severity: TelemetrySeverity.info,
    operationGroup: 'lan.transfer',
    operationRole: 'success',
    description: 'Emitted when LAN file transfer completes.',
    allowedProperties: {'bytes_transferred', 'duration_ms'},
    requiredProperties: {'bytes_transferred'},
    propertyTypes: {'bytes_transferred': 'integer', 'duration_ms': 'integer'},
  );

  static const aiChatRequest = TelemetryEventDefinition(
    name: 'ai.chat.request',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ai',
    severity: TelemetrySeverity.info,
    operationGroup: 'ai.chat',
    operationRole: 'started',
    description: 'Emitted when a client-side AI chat prompt request is sent.',
    allowedProperties: {'model_type', 'token_estimate'},
    requiredProperties: {},
    propertyTypes: {'model_type': 'string', 'token_estimate': 'integer'},
  );

  static const aiChatResponse = TelemetryEventDefinition(
    name: 'ai.chat.response',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ai',
    severity: TelemetrySeverity.info,
    operationGroup: 'ai.chat',
    operationRole: 'success',
    description: 'Emitted when an AI response is successfully received.',
    allowedProperties: {'latency_ms', 'status'},
    requiredProperties: {},
    propertyTypes: {'latency_ms': 'integer', 'status': 'string'},
  );

  static const aiChatFailed = TelemetryEventDefinition(
    name: 'ai.chat.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'ai',
    severity: TelemetrySeverity.error,
    operationGroup: 'ai.chat',
    operationRole: 'failure',
    description: 'Emitted when an AI chat request fails.',
    allowedProperties: {'http_status', 'provider'},
    requiredProperties: {},
    propertyTypes: {'http_status': 'integer', 'provider': 'string'},
  );

  static const appDiagnosticLog = TelemetryEventDefinition(
    name: 'app.diagnostic.log',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'app',
    severity: TelemetrySeverity.warn,
    operationGroup: 'app.diagnostic',
    operationRole: 'diagnostic',
    description:
        'General diagnostic log entry for client and system diagnostics.',
    allowedProperties: {
      'category',
      'details',
      'direct_error',
      'message',
      'stage',
    },
    requiredProperties: {},
    propertyTypes: {
      'category': 'string',
      'details': 'string',
      'direct_error': 'string',
      'message': 'string',
      'stage': 'string',
    },
  );

  static const appErrorCaptured = TelemetryEventDefinition(
    name: 'app.error.captured',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'app',
    severity: TelemetrySeverity.error,
    operationGroup: 'app.error',
    operationRole: 'failure',
    description: 'Emitted when an uncaught application error is captured.',
    allowedProperties: {'category', 'details', 'message', 'stage'},
    requiredProperties: {'message'},
    propertyTypes: {
      'category': 'string',
      'details': 'string',
      'message': 'string',
      'stage': 'string',
    },
  );

  static const appCrashReported = TelemetryEventDefinition(
    name: 'app.crash.reported',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'app',
    severity: TelemetrySeverity.critical,
    operationGroup: 'app.crash',
    operationRole: 'failure',
    description: 'Emitted when a fatal application crash is reported.',
    allowedProperties: {'category', 'details', 'message', 'stage'},
    requiredProperties: {'message'},
    propertyTypes: {
      'category': 'string',
      'details': 'string',
      'message': 'string',
      'stage': 'string',
    },
  );

  static const telemetryBatchUploaded = TelemetryEventDefinition(
    name: 'telemetry.batch.uploaded',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'telemetry',
    severity: TelemetrySeverity.info,
    operationGroup: 'telemetry.batch',
    operationRole: 'success',
    description:
        'Emitted when a telemetry batch is successfully acknowledged by server.',
    allowedProperties: {'duration_ms', 'record_count'},
    requiredProperties: {'record_count'},
    propertyTypes: {'duration_ms': 'integer', 'record_count': 'integer'},
  );

  static const telemetryBatchFailed = TelemetryEventDefinition(
    name: 'telemetry.batch.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'telemetry',
    severity: TelemetrySeverity.warn,
    operationGroup: 'telemetry.batch',
    operationRole: 'failure',
    description: 'Emitted when a telemetry batch upload fails.',
    allowedProperties: {'error_type', 'http_status', 'retry_count'},
    requiredProperties: {},
    propertyTypes: {
      'error_type': 'string',
      'http_status': 'integer',
      'retry_count': 'integer',
    },
  );

  static const List<TelemetryEventDefinition> all = <TelemetryEventDefinition>[
    appLifecycleStarted,
    appLifecycleBackgrounded,
    appLifecycleForegrounded,
    networkQuicConnected,
    networkQuicFailed,
    networkRelayConnected,
    networkRelayFallback,
    networkRelayFailed,
    sshSessionStarted,
    sshSessionTerminated,
    sshSessionFailed,
    sshSessionConnected,
    sftpTransferStarted,
    sftpTransferCompleted,
    sftpTransferFailed,
    lanDiscoveryPeerFound,
    lanTransferCompleted,
    aiChatRequest,
    aiChatResponse,
    aiChatFailed,
    appDiagnosticLog,
    appErrorCaptured,
    appCrashReported,
    telemetryBatchUploaded,
    telemetryBatchFailed,
  ];
}
