import 'telemetry_model.dart';

class TelemetryEventDefinition {
  const TelemetryEventDefinition({
    required this.name,
    required this.version,
    required this.recordType,
    required this.feature,
    required this.severity,
    required this.allowedProperties,
    this.requiredProperties = const {},
  });

  final String name;
  final int version;
  final TelemetryRecordType recordType;
  final String feature;
  final TelemetrySeverity severity;
  final Set<String> allowedProperties;
  final Set<String> requiredProperties;
}

class TelemetryErrorCodeDefinition {
  const TelemetryErrorCodeDefinition({
    required this.code,
    required this.category,
    required this.terminalFailure,
  });

  final String code;
  final String category;
  final bool terminalFailure;
}

class TelemetryCatalog {
  TelemetryCatalog({bool registerDefaults = true}) {
    if (registerDefaults) {
      _registerDefaults();
    }
  }

  static final TelemetryCatalog instance = TelemetryCatalog();

  final Map<String, TelemetryEventDefinition> _events = {};
  final Map<String, TelemetryErrorCodeDefinition> _errors = {};

  void registerEvent(TelemetryEventDefinition def) {
    _events[def.name] = def;
  }

  void registerError(TelemetryErrorCodeDefinition def) {
    _errors[def.code] = def;
  }

  void _registerDefaults() {
    final defaultEvents = <TelemetryEventDefinition>[
      const TelemetryEventDefinition(
        name: 'app.lifecycle.started',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'app',
        severity: TelemetrySeverity.info,
        allowedProperties: {'start_type', 'cold_start'},
      ),
      const TelemetryEventDefinition(
        name: 'app.lifecycle.backgrounded',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'app',
        severity: TelemetrySeverity.info,
        allowedProperties: {'active_sessions'},
      ),
      const TelemetryEventDefinition(
        name: 'app.lifecycle.foregrounded',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'app',
        severity: TelemetrySeverity.info,
        allowedProperties: {'background_duration_ms'},
      ),
      const TelemetryEventDefinition(
        name: 'network.quic.connected',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'network',
        severity: TelemetrySeverity.info,
        allowedProperties: {'rtt_ms', 'protocol_version'},
      ),
      const TelemetryEventDefinition(
        name: 'network.quic.failed',
        version: 1,
        recordType: TelemetryRecordType.diagnostic,
        feature: 'network',
        severity: TelemetrySeverity.warn,
        allowedProperties: {'reason', 'fallback_used'},
      ),
      const TelemetryEventDefinition(
        name: 'network.relay.connected',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'network',
        severity: TelemetrySeverity.info,
        allowedProperties: {'relay_region'},
      ),
      const TelemetryEventDefinition(
        name: 'network.relay.fallback',
        version: 1,
        recordType: TelemetryRecordType.diagnostic,
        feature: 'network',
        severity: TelemetrySeverity.warn,
        allowedProperties: {'direct_error'},
      ),
      const TelemetryEventDefinition(
        name: 'ssh.session.started',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        allowedProperties: {'session_type', 'auth_method'},
      ),
      const TelemetryEventDefinition(
        name: 'ssh.session.terminated',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        allowedProperties: {'duration_ms', 'exit_code'},
      ),
      const TelemetryEventDefinition(
        name: 'ssh.session.failed',
        version: 1,
        recordType: TelemetryRecordType.diagnostic,
        feature: 'ssh',
        severity: TelemetrySeverity.error,
        allowedProperties: {'stage', 'retry_count'},
      ),
      const TelemetryEventDefinition(
        name: 'sftp.transfer.started',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'sftp',
        severity: TelemetrySeverity.info,
        allowedProperties: {'direction', 'file_size_bytes'},
        requiredProperties: {'direction'},
      ),
      const TelemetryEventDefinition(
        name: 'sftp.transfer.completed',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'sftp',
        severity: TelemetrySeverity.info,
        allowedProperties: {'direction', 'bytes_transferred', 'duration_ms'},
        requiredProperties: {'direction', 'bytes_transferred'},
      ),
      const TelemetryEventDefinition(
        name: 'sftp.transfer.failed',
        version: 1,
        recordType: TelemetryRecordType.diagnostic,
        feature: 'sftp',
        severity: TelemetrySeverity.error,
        allowedProperties: {'direction', 'bytes_transferred', 'stage'},
        requiredProperties: {'direction'},
      ),
      const TelemetryEventDefinition(
        name: 'lan.discovery.peer_found',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'lan_share',
        severity: TelemetrySeverity.info,
        allowedProperties: {'peer_count'},
      ),
      const TelemetryEventDefinition(
        name: 'lan.transfer.completed',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'lan_share',
        severity: TelemetrySeverity.info,
        allowedProperties: {'bytes_transferred', 'duration_ms'},
        requiredProperties: {'bytes_transferred'},
      ),
      const TelemetryEventDefinition(
        name: 'ai.chat.request',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'ai',
        severity: TelemetrySeverity.info,
        allowedProperties: {'model_type', 'token_estimate'},
      ),
      const TelemetryEventDefinition(
        name: 'ai.chat.response',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'ai',
        severity: TelemetrySeverity.info,
        allowedProperties: {'latency_ms', 'status'},
      ),
      const TelemetryEventDefinition(
        name: 'ai.chat.failed',
        version: 1,
        recordType: TelemetryRecordType.diagnostic,
        feature: 'ai',
        severity: TelemetrySeverity.error,
        allowedProperties: {'provider', 'http_status'},
      ),
      const TelemetryEventDefinition(
        name: 'telemetry.batch.uploaded',
        version: 1,
        recordType: TelemetryRecordType.analytics,
        feature: 'telemetry',
        severity: TelemetrySeverity.info,
        allowedProperties: {'record_count', 'duration_ms'},
        requiredProperties: {'record_count'},
      ),
      const TelemetryEventDefinition(
        name: 'telemetry.batch.failed',
        version: 1,
        recordType: TelemetryRecordType.diagnostic,
        feature: 'telemetry',
        severity: TelemetrySeverity.warn,
        allowedProperties: {'error_type', 'http_status', 'retry_count'},
      ),
    ];

    for (final ev in defaultEvents) {
      _events[ev.name] = ev;
    }

    final defaultErrors = <TelemetryErrorCodeDefinition>[
      const TelemetryErrorCodeDefinition(
        code: 'NET_QUIC_CONN_REFUSED',
        category: 'network',
        terminalFailure: false,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'NET_QUIC_TIMEOUT',
        category: 'network',
        terminalFailure: false,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'NET_RELAY_UNAVAILABLE',
        category: 'network',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'SSH_AUTH_FAILED',
        category: 'ssh',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'SSH_HOST_KEY_MISMATCH',
        category: 'ssh',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'SSH_TIMEOUT',
        category: 'ssh',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'SFTP_PERMISSION_DENIED',
        category: 'sftp',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'SFTP_FILE_NOT_FOUND',
        category: 'sftp',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'SFTP_TRANSFER_ABORTED',
        category: 'sftp',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'LAN_PEER_DISCONNECTED',
        category: 'lan',
        terminalFailure: false,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'LAN_HANDSHAKE_FAILED',
        category: 'lan',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'AI_RATE_LIMITED',
        category: 'ai',
        terminalFailure: false,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'AI_SERVICE_UNAVAILABLE',
        category: 'ai',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'TELEMETRY_AUTH_FAILED',
        category: 'telemetry',
        terminalFailure: true,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'TELEMETRY_NETWORK_ERROR',
        category: 'telemetry',
        terminalFailure: false,
      ),
      const TelemetryErrorCodeDefinition(
        code: 'TELEMETRY_STORAGE_FULL',
        category: 'telemetry',
        terminalFailure: false,
      ),
    ];

    for (final err in defaultErrors) {
      _errors[err.code] = err;
    }
  }

  bool isValidRecord(TelemetryEventRecord record) {
    final def = _events[record.eventName];
    if (def == null) return false;
    if (record.eventVersion != def.version) return false;

    // Check required properties
    for (final req in def.requiredProperties) {
      if (!record.properties.containsKey(req)) return false;
    }

    // Check allowed properties
    for (final key in record.properties.keys) {
      if (!def.allowedProperties.contains(key)) return false;
    }

    // Check error code if present
    if (record.error != null) {
      if (!_errors.containsKey(record.error!.errorCode)) return false;
    }

    return true;
  }

  bool isValidErrorCode(String code) => _errors.containsKey(code);

  bool isTerminalFailure(String code) => _errors[code]?.terminalFailure ?? true;
}
