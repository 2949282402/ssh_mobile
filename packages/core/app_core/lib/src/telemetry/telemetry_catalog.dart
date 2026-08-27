import 'generated/error_codes.dart';
import 'generated/telemetry_events.dart';
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
    // 从 contracts/telemetry 生成的常量目录注册全部事件定义，禁止业务代码
    // 硬编码事件名、属性白名单或错误码。
    final defaultEvents = <TelemetryEventDefinition>[
      TelemetryEvents.appLifecycleStarted,
      TelemetryEvents.appLifecycleBackgrounded,
      TelemetryEvents.appLifecycleForegrounded,
      TelemetryEvents.networkQuicConnected,
      TelemetryEvents.networkQuicFailed,
      TelemetryEvents.networkRelayConnected,
      TelemetryEvents.networkRelayFallback,
      TelemetryEvents.sshSessionStarted,
      TelemetryEvents.sshSessionTerminated,
      TelemetryEvents.sshSessionFailed,
      TelemetryEvents.sftpTransferStarted,
      TelemetryEvents.sftpTransferCompleted,
      TelemetryEvents.sftpTransferFailed,
      TelemetryEvents.lanDiscoveryPeerFound,
      TelemetryEvents.lanTransferCompleted,
      TelemetryEvents.aiChatRequest,
      TelemetryEvents.aiChatResponse,
      TelemetryEvents.aiChatFailed,
      TelemetryEvents.appDiagnosticLog,
      TelemetryEvents.telemetryBatchUploaded,
      TelemetryEvents.telemetryBatchFailed,
    ];

    for (final ev in defaultEvents) {
      _events[ev.name] = ev;
    }

    final defaultErrors = <TelemetryErrorCodeDefinition>[
      TelemetryErrorCodes.netQuicConnRefused,
      TelemetryErrorCodes.netQuicTimeout,
      TelemetryErrorCodes.netRelayUnavailable,
      TelemetryErrorCodes.sshAuthFailed,
      TelemetryErrorCodes.sshHostKeyMismatch,
      TelemetryErrorCodes.sshTimeout,
      TelemetryErrorCodes.sftpPermissionDenied,
      TelemetryErrorCodes.sftpFileNotFound,
      TelemetryErrorCodes.sftpTransferAborted,
      TelemetryErrorCodes.lanPeerDisconnected,
      TelemetryErrorCodes.lanHandshakeFailed,
      TelemetryErrorCodes.aiRateLimited,
      TelemetryErrorCodes.aiServiceUnavailable,
      TelemetryErrorCodes.telemetryAuthFailed,
      TelemetryErrorCodes.telemetryNetworkError,
      TelemetryErrorCodes.telemetryStorageFull,
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
