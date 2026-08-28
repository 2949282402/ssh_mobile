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
    this.propertyTypes = const {},
    this.description = '',
    this.operationGroup = '',
    this.operationRole = '',
    this.businessOperation = false,
  });

  final String name;
  final int version;
  final TelemetryRecordType recordType;
  final String feature;
  final TelemetrySeverity severity;
  final Set<String> allowedProperties;
  final Set<String> requiredProperties;
  final Map<String, String> propertyTypes;
  final String description;
  final String operationGroup;
  final String operationRole;
  final bool businessOperation;
}

class TelemetryErrorCodeDefinition {
  const TelemetryErrorCodeDefinition({
    required this.code,
    required this.category,
    required this.terminalFailure,
    this.description = '',
  });

  final String code;
  final String category;
  final bool terminalFailure;
  final String description;
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

  /// Returns a registered event definition without exposing the mutable
  /// registry. Consumers such as [TelemetryLogSink] use this to enforce the
  /// same contract that [TelemetryClient] uses before a record is persisted.
  TelemetryEventDefinition? eventDefinition(String name) => _events[name];

  /// Returns a registered error-code definition, when present.
  TelemetryErrorCodeDefinition? errorDefinition(String code) => _errors[code];

  void _registerDefaults() {
    // 从 contracts/telemetry 生成的常量目录注册全部事件定义，禁止业务代码
    // 硬编码事件名、属性白名单或错误码。
    for (final ev in TelemetryEvents.all) {
      _events[ev.name] = ev;
    }

    for (final err in TelemetryErrorCodes.all) {
      _errors[err.code] = err;
    }
  }

  bool isValidRecord(TelemetryEventRecord record) {
    final def = _events[record.eventName];
    if (def == null) return false;
    if (record.eventVersion != def.version) return false;
    if (record.recordType != def.recordType) return false;
    if (record.feature != def.feature) return false;
    if (record.severity != def.severity) return false;

    // Check required properties
    for (final req in def.requiredProperties) {
      if (!record.properties.containsKey(req)) return false;
    }

    // Check allowed properties
    for (final key in record.properties.keys) {
      if (!def.allowedProperties.contains(key)) return false;
      final type = def.propertyTypes[key];
      if (type == null || !_matchesPropertyType(type, record.properties[key])) {
        return false;
      }
    }

    // Check error code if present
    if (record.error != null) {
      final errorDef = _errors[record.error!.errorCode];
      if (errorDef == null) return false;
      if (record.error!.category != errorDef.category) return false;
      if (record.error!.terminalFailure != errorDef.terminalFailure) {
        return false;
      }
    }

    return true;
  }

  bool isValidErrorCode(String code) => _errors.containsKey(code);

  bool isTerminalFailure(String code) => _errors[code]?.terminalFailure ?? true;

  bool _matchesPropertyType(String type, dynamic value) {
    switch (type) {
      case 'string':
        return value is String;
      case 'integer':
        // JSON numbers are integer-valued when they have no fractional part;
        // accept both Dart representations so decoded `1` and `1.0` agree
        // with the Go and TypeScript catalog validators.
        return value is int ||
            (value is double &&
                value.isFinite &&
                value == value.truncateToDouble());
      case 'boolean':
        return value is bool;
      default:
        return false;
    }
  }
}
