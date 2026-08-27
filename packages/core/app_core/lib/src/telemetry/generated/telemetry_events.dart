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
    allowedProperties: {'cold_start', 'start_type'},
    requiredProperties: {},
  );

  static const appLifecycleBackgrounded = TelemetryEventDefinition(
    name: 'app.lifecycle.backgrounded',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'app',
    severity: TelemetrySeverity.info,
    allowedProperties: {'active_sessions'},
    requiredProperties: {},
  );

  static const appLifecycleForegrounded = TelemetryEventDefinition(
    name: 'app.lifecycle.foregrounded',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'app',
    severity: TelemetrySeverity.info,
    allowedProperties: {'background_duration_ms'},
    requiredProperties: {},
  );

  static const networkQuicConnected = TelemetryEventDefinition(
    name: 'network.quic.connected',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'network',
    severity: TelemetrySeverity.info,
    allowedProperties: {'protocol_version', 'rtt_ms'},
    requiredProperties: {},
  );

  static const networkQuicFailed = TelemetryEventDefinition(
    name: 'network.quic.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'network',
    severity: TelemetrySeverity.warn,
    allowedProperties: {'fallback_used', 'reason'},
    requiredProperties: {},
  );

  static const networkRelayConnected = TelemetryEventDefinition(
    name: 'network.relay.connected',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'network',
    severity: TelemetrySeverity.info,
    allowedProperties: {'relay_region'},
    requiredProperties: {},
  );

  static const networkRelayFallback = TelemetryEventDefinition(
    name: 'network.relay.fallback',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'network',
    severity: TelemetrySeverity.warn,
    allowedProperties: {'direct_error'},
    requiredProperties: {},
  );

  static const sshSessionStarted = TelemetryEventDefinition(
    name: 'ssh.session.started',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    allowedProperties: {'auth_method', 'session_type'},
    requiredProperties: {},
  );

  static const sshSessionTerminated = TelemetryEventDefinition(
    name: 'ssh.session.terminated',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    allowedProperties: {'duration_ms', 'exit_code'},
    requiredProperties: {},
  );

  static const sshSessionFailed = TelemetryEventDefinition(
    name: 'ssh.session.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'ssh',
    severity: TelemetrySeverity.error,
    allowedProperties: {'retry_count', 'stage'},
    requiredProperties: {},
  );

  static const sftpTransferStarted = TelemetryEventDefinition(
    name: 'sftp.transfer.started',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'sftp',
    severity: TelemetrySeverity.info,
    allowedProperties: {'direction', 'file_size_bytes'},
    requiredProperties: {'direction'},
  );

  static const sftpTransferCompleted = TelemetryEventDefinition(
    name: 'sftp.transfer.completed',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'sftp',
    severity: TelemetrySeverity.info,
    allowedProperties: {'bytes_transferred', 'direction', 'duration_ms'},
    requiredProperties: {'bytes_transferred', 'direction'},
  );

  static const sftpTransferFailed = TelemetryEventDefinition(
    name: 'sftp.transfer.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'sftp',
    severity: TelemetrySeverity.error,
    allowedProperties: {'bytes_transferred', 'direction', 'stage'},
    requiredProperties: {'direction'},
  );

  static const lanDiscoveryPeerFound = TelemetryEventDefinition(
    name: 'lan.discovery.peer_found',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'lan_share',
    severity: TelemetrySeverity.info,
    allowedProperties: {'peer_count'},
    requiredProperties: {},
  );

  static const lanTransferCompleted = TelemetryEventDefinition(
    name: 'lan.transfer.completed',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'lan_share',
    severity: TelemetrySeverity.info,
    allowedProperties: {'bytes_transferred', 'duration_ms'},
    requiredProperties: {'bytes_transferred'},
  );

  static const aiChatRequest = TelemetryEventDefinition(
    name: 'ai.chat.request',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ai',
    severity: TelemetrySeverity.info,
    allowedProperties: {'model_type', 'token_estimate'},
    requiredProperties: {},
  );

  static const aiChatResponse = TelemetryEventDefinition(
    name: 'ai.chat.response',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ai',
    severity: TelemetrySeverity.info,
    allowedProperties: {'latency_ms', 'status'},
    requiredProperties: {},
  );

  static const aiChatFailed = TelemetryEventDefinition(
    name: 'ai.chat.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'ai',
    severity: TelemetrySeverity.error,
    allowedProperties: {'http_status', 'provider'},
    requiredProperties: {},
  );

  static const appDiagnosticLog = TelemetryEventDefinition(
    name: 'app.diagnostic.log',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'app',
    severity: TelemetrySeverity.warn,
    allowedProperties: {'category', 'details', 'direct_error', 'message', 'stage'},
    requiredProperties: {},
  );

  static const telemetryBatchUploaded = TelemetryEventDefinition(
    name: 'telemetry.batch.uploaded',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'telemetry',
    severity: TelemetrySeverity.info,
    allowedProperties: {'duration_ms', 'record_count'},
    requiredProperties: {'record_count'},
  );

  static const telemetryBatchFailed = TelemetryEventDefinition(
    name: 'telemetry.batch.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'telemetry',
    severity: TelemetrySeverity.warn,
    allowedProperties: {'error_type', 'http_status', 'retry_count'},
    requiredProperties: {},
  );

}
