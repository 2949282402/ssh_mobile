// App Scope 遥测事件/错误码常量镜像。
//
// 任务要求生产者统一使用 `TelemetryEvents` / `TelemetryErrorCodes` 类型化常量
// （来自 `package:app_core/app_core.dart`）。当前 app_core 的公开导出不包含
// generated 常量文件，且本任务不允许修改 packages/core/app_core。因此这里在
// App Scope 维护一份与 `contracts/telemetry` 生成目录逐项一致的常量镜像，供
// 业务生产者与测试断言使用；`test/services/telemetry/telemetry_contract_test.dart`
// 会与 `TelemetryCatalog.instance` 实际注册项做一致性校验，防止镜像漂移。
//
// 禁止在此文件中硬编码 contracts 之外的字符串；新增事件/错误码必须先更新
// `contracts/telemetry` 并重新生成，再同步本镜像。

import 'package:app_core/app_core.dart';

/// App Scope 事件定义镜像，属性白名单与 app_core generated 常量一致。
abstract final class AppTelemetryEvents {
  static const appLifecycleStarted = TelemetryEventDefinition(
    name: 'app.lifecycle.started',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'app',
    severity: TelemetrySeverity.info,
    allowedProperties: {'cold_start', 'start_type'},
  );

  static const appLifecycleBackgrounded = TelemetryEventDefinition(
    name: 'app.lifecycle.backgrounded',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'app',
    severity: TelemetrySeverity.info,
    allowedProperties: {'active_sessions'},
  );

  static const appLifecycleForegrounded = TelemetryEventDefinition(
    name: 'app.lifecycle.foregrounded',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'app',
    severity: TelemetrySeverity.info,
    allowedProperties: {'background_duration_ms'},
  );

  static const networkQuicConnected = TelemetryEventDefinition(
    name: 'network.quic.connected',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'network',
    severity: TelemetrySeverity.info,
    allowedProperties: {'protocol_version', 'rtt_ms'},
  );

  static const networkQuicFailed = TelemetryEventDefinition(
    name: 'network.quic.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'network',
    severity: TelemetrySeverity.warn,
    allowedProperties: {'fallback_used', 'reason'},
  );

  static const networkRelayConnected = TelemetryEventDefinition(
    name: 'network.relay.connected',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'network',
    severity: TelemetrySeverity.info,
    allowedProperties: {'relay_region'},
  );

  static const networkRelayFallback = TelemetryEventDefinition(
    name: 'network.relay.fallback',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'network',
    severity: TelemetrySeverity.warn,
    allowedProperties: {'direct_error'},
  );

  static const sshSessionStarted = TelemetryEventDefinition(
    name: 'ssh.session.started',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    allowedProperties: {'auth_method', 'session_type'},
  );

  static const sshSessionTerminated = TelemetryEventDefinition(
    name: 'ssh.session.terminated',
    version: 1,
    recordType: TelemetryRecordType.analytics,
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    allowedProperties: {'duration_ms', 'exit_code'},
  );

  static const sshSessionFailed = TelemetryEventDefinition(
    name: 'ssh.session.failed',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'ssh',
    severity: TelemetrySeverity.error,
    allowedProperties: {'retry_count', 'stage'},
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

  static const appDiagnosticLog = TelemetryEventDefinition(
    name: 'app.diagnostic.log',
    version: 1,
    recordType: TelemetryRecordType.diagnostic,
    feature: 'app',
    severity: TelemetrySeverity.warn,
    allowedProperties: {'category', 'details', 'direct_error', 'message', 'stage'},
  );
}

/// App Scope 错误码定义镜像，与 app_core generated 常量逐项一致。
abstract final class AppTelemetryErrorCodes {
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