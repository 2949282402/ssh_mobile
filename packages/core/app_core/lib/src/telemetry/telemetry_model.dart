enum TelemetryRecordType {
  analytics('analytics'),
  diagnostic('diagnostic');

  const TelemetryRecordType(this.wireValue);
  final String wireValue;

  static TelemetryRecordType fromWireValue(String value) {
    for (final type in values) {
      if (type.wireValue == value) return type;
    }
    return TelemetryRecordType.analytics;
  }
}

enum TelemetrySeverity {
  info('info'),
  warn('warn'),
  error('error'),
  critical('critical');

  const TelemetrySeverity(this.wireValue);
  final String wireValue;

  static TelemetrySeverity fromWireValue(String value) {
    for (final s in values) {
      if (s.wireValue == value) return s;
    }
    return TelemetrySeverity.info;
  }
}

enum TelemetrySyncState {
  /// 尚未写入本地存储的新记录（wire 值 `new`）。
  ///
  /// 调用方在插入时应当把它转换为 [pending]；该状态仅用于统一表达
  /// “新建但尚未进入上传队列”的瞬间。
  new_('new'),
  pending('pending'),
  synced('synced'),
  rejected('rejected');

  const TelemetrySyncState(this.wireValue);
  final String wireValue;

  static TelemetrySyncState fromWireValue(String value) {
    for (final s in values) {
      if (s.wireValue == value) return s;
    }
    return TelemetrySyncState.pending;
  }
}

class TelemetryErrorDetail {
  const TelemetryErrorDetail({
    required this.errorCode,
    required this.category,
    required this.terminalFailure,
    this.message,
    this.stackTrace,
  });

  final String errorCode;
  final String category;
  final bool terminalFailure;
  final String? message;
  final String? stackTrace;

  Map<String, dynamic> toJson() => {
    'errorCode': errorCode,
    'category': category,
    'terminalFailure': terminalFailure,
    if (message != null) 'message': message,
    if (stackTrace != null) 'stackTrace': stackTrace,
  };

  factory TelemetryErrorDetail.fromJson(Map<String, dynamic> json) {
    return TelemetryErrorDetail(
      errorCode: json['errorCode'] as String? ?? 'UNKNOWN',
      category: json['category'] as String? ?? 'general',
      terminalFailure: json['terminalFailure'] as bool? ?? true,
      message: json['message'] as String?,
      stackTrace: json['stackTrace'] as String?,
    );
  }
}

class TelemetryEventRecord {
  const TelemetryEventRecord({
    required this.eventId,
    required this.recordType,
    required this.eventName,
    required this.eventVersion,
    required this.deviceId,
    required this.sessionId,
    required this.traceId,
    required this.occurredAt,
    required this.feature,
    required this.severity,
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    this.properties = const {},
    this.error,
    this.syncState = TelemetrySyncState.pending,
    this.logicalDeletedAt,
    this.retryCount = 0,
  });

  final String eventId;
  final TelemetryRecordType recordType;
  final String eventName;
  final int eventVersion;
  final String deviceId;
  final String sessionId;
  final String traceId;
  final DateTime occurredAt;
  final String feature;
  final TelemetrySeverity severity;
  final String appVersion;
  final String buildNumber;
  final String platform;
  final Map<String, dynamic> properties;
  final TelemetryErrorDetail? error;
  final TelemetrySyncState syncState;
  final DateTime? logicalDeletedAt;
  final int retryCount;

  TelemetryEventRecord copyWith({
    String? eventId,
    TelemetryRecordType? recordType,
    String? eventName,
    int? eventVersion,
    String? deviceId,
    String? sessionId,
    String? traceId,
    DateTime? occurredAt,
    String? feature,
    TelemetrySeverity? severity,
    String? appVersion,
    String? buildNumber,
    String? platform,
    Map<String, dynamic>? properties,
    TelemetryErrorDetail? error,
    TelemetrySyncState? syncState,
    DateTime? logicalDeletedAt,
    bool clearLogicalDeletedAt = false,
    int? retryCount,
  }) {
    return TelemetryEventRecord(
      eventId: eventId ?? this.eventId,
      recordType: recordType ?? this.recordType,
      eventName: eventName ?? this.eventName,
      eventVersion: eventVersion ?? this.eventVersion,
      deviceId: deviceId ?? this.deviceId,
      sessionId: sessionId ?? this.sessionId,
      traceId: traceId ?? this.traceId,
      occurredAt: occurredAt ?? this.occurredAt,
      feature: feature ?? this.feature,
      severity: severity ?? this.severity,
      appVersion: appVersion ?? this.appVersion,
      buildNumber: buildNumber ?? this.buildNumber,
      platform: platform ?? this.platform,
      properties: properties ?? this.properties,
      error: error ?? this.error,
      syncState: syncState ?? this.syncState,
      logicalDeletedAt: clearLogicalDeletedAt
          ? null
          : (logicalDeletedAt ?? this.logicalDeletedAt),
      retryCount: retryCount ?? this.retryCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'recordType': recordType.wireValue,
    'eventName': eventName,
    'eventVersion': eventVersion,
    'deviceId': deviceId,
    'sessionId': sessionId,
    'traceId': traceId,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'feature': feature,
    'severity': severity.wireValue,
    'appVersion': appVersion,
    'buildNumber': buildNumber,
    'platform': platform,
    'properties': properties,
    if (error != null) 'error': error!.toJson(),
  };

  factory TelemetryEventRecord.fromJson(Map<String, dynamic> json) {
    return TelemetryEventRecord(
      eventId: json['eventId'] as String,
      recordType: TelemetryRecordType.fromWireValue(
        json['recordType'] as String? ?? 'analytics',
      ),
      eventName: json['eventName'] as String,
      eventVersion: json['eventVersion'] as int? ?? 1,
      deviceId: json['deviceId'] as String,
      sessionId: json['sessionId'] as String,
      traceId: json['traceId'] as String,
      occurredAt: DateTime.parse(json['occurredAt'] as String),
      feature: json['feature'] as String? ?? 'app',
      severity: TelemetrySeverity.fromWireValue(
        json['severity'] as String? ?? 'info',
      ),
      appVersion: json['appVersion'] as String? ?? '',
      buildNumber: json['buildNumber'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      properties: (json['properties'] as Map<String, dynamic>?) ?? {},
      error: json['error'] != null
          ? TelemetryErrorDetail.fromJson(json['error'] as Map<String, dynamic>)
          : null,
    );
  }
}
