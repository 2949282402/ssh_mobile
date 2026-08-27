// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'telemetry_database.dart';

// ignore_for_file: type=lint
class $TelemetryRecordsTable extends TelemetryRecords
    with TableInfo<$TelemetryRecordsTable, TelemetryRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TelemetryRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _eventIdMeta = const VerificationMeta(
    'eventId',
  );
  @override
  late final GeneratedColumn<String> eventId = GeneratedColumn<String>(
    'event_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _recordTypeMeta = const VerificationMeta(
    'recordType',
  );
  @override
  late final GeneratedColumn<String> recordType = GeneratedColumn<String>(
    'record_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _eventNameMeta = const VerificationMeta(
    'eventName',
  );
  @override
  late final GeneratedColumn<String> eventName = GeneratedColumn<String>(
    'event_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _eventVersionMeta = const VerificationMeta(
    'eventVersion',
  );
  @override
  late final GeneratedColumn<int> eventVersion = GeneratedColumn<int>(
    'event_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _traceIdMeta = const VerificationMeta(
    'traceId',
  );
  @override
  late final GeneratedColumn<String> traceId = GeneratedColumn<String>(
    'trace_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _occurredAtMeta = const VerificationMeta(
    'occurredAt',
  );
  @override
  late final GeneratedColumn<String> occurredAt = GeneratedColumn<String>(
    'occurred_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _featureMeta = const VerificationMeta(
    'feature',
  );
  @override
  late final GeneratedColumn<String> feature = GeneratedColumn<String>(
    'feature',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _severityMeta = const VerificationMeta(
    'severity',
  );
  @override
  late final GeneratedColumn<String> severity = GeneratedColumn<String>(
    'severity',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _appVersionMeta = const VerificationMeta(
    'appVersion',
  );
  @override
  late final GeneratedColumn<String> appVersion = GeneratedColumn<String>(
    'app_version',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _buildNumberMeta = const VerificationMeta(
    'buildNumber',
  );
  @override
  late final GeneratedColumn<String> buildNumber = GeneratedColumn<String>(
    'build_number',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _platformMeta = const VerificationMeta(
    'platform',
  );
  @override
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
    'platform',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _propertiesMeta = const VerificationMeta(
    'properties',
  );
  @override
  late final GeneratedColumn<String> properties = GeneratedColumn<String>(
    'properties',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _syncStateMeta = const VerificationMeta(
    'syncState',
  );
  @override
  late final GeneratedColumn<String> syncState = GeneratedColumn<String>(
    'sync_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _logicalDeletedAtMeta = const VerificationMeta(
    'logicalDeletedAt',
  );
  @override
  late final GeneratedColumn<String> logicalDeletedAt = GeneratedColumn<String>(
    'logical_deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _retryCountMeta = const VerificationMeta(
    'retryCount',
  );
  @override
  late final GeneratedColumn<int> retryCount = GeneratedColumn<int>(
    'retry_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    eventId,
    recordType,
    eventName,
    eventVersion,
    deviceId,
    sessionId,
    traceId,
    occurredAt,
    feature,
    severity,
    appVersion,
    buildNumber,
    platform,
    properties,
    error,
    syncState,
    logicalDeletedAt,
    retryCount,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'telemetry_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<TelemetryRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('event_id')) {
      context.handle(
        _eventIdMeta,
        eventId.isAcceptableOrUnknown(data['event_id']!, _eventIdMeta),
      );
    } else if (isInserting) {
      context.missing(_eventIdMeta);
    }
    if (data.containsKey('record_type')) {
      context.handle(
        _recordTypeMeta,
        recordType.isAcceptableOrUnknown(data['record_type']!, _recordTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_recordTypeMeta);
    }
    if (data.containsKey('event_name')) {
      context.handle(
        _eventNameMeta,
        eventName.isAcceptableOrUnknown(data['event_name']!, _eventNameMeta),
      );
    } else if (isInserting) {
      context.missing(_eventNameMeta);
    }
    if (data.containsKey('event_version')) {
      context.handle(
        _eventVersionMeta,
        eventVersion.isAcceptableOrUnknown(
          data['event_version']!,
          _eventVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_eventVersionMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('trace_id')) {
      context.handle(
        _traceIdMeta,
        traceId.isAcceptableOrUnknown(data['trace_id']!, _traceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_traceIdMeta);
    }
    if (data.containsKey('occurred_at')) {
      context.handle(
        _occurredAtMeta,
        occurredAt.isAcceptableOrUnknown(data['occurred_at']!, _occurredAtMeta),
      );
    } else if (isInserting) {
      context.missing(_occurredAtMeta);
    }
    if (data.containsKey('feature')) {
      context.handle(
        _featureMeta,
        feature.isAcceptableOrUnknown(data['feature']!, _featureMeta),
      );
    } else if (isInserting) {
      context.missing(_featureMeta);
    }
    if (data.containsKey('severity')) {
      context.handle(
        _severityMeta,
        severity.isAcceptableOrUnknown(data['severity']!, _severityMeta),
      );
    } else if (isInserting) {
      context.missing(_severityMeta);
    }
    if (data.containsKey('app_version')) {
      context.handle(
        _appVersionMeta,
        appVersion.isAcceptableOrUnknown(data['app_version']!, _appVersionMeta),
      );
    } else if (isInserting) {
      context.missing(_appVersionMeta);
    }
    if (data.containsKey('build_number')) {
      context.handle(
        _buildNumberMeta,
        buildNumber.isAcceptableOrUnknown(
          data['build_number']!,
          _buildNumberMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_buildNumberMeta);
    }
    if (data.containsKey('platform')) {
      context.handle(
        _platformMeta,
        platform.isAcceptableOrUnknown(data['platform']!, _platformMeta),
      );
    } else if (isInserting) {
      context.missing(_platformMeta);
    }
    if (data.containsKey('properties')) {
      context.handle(
        _propertiesMeta,
        properties.isAcceptableOrUnknown(data['properties']!, _propertiesMeta),
      );
    } else if (isInserting) {
      context.missing(_propertiesMeta);
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    if (data.containsKey('sync_state')) {
      context.handle(
        _syncStateMeta,
        syncState.isAcceptableOrUnknown(data['sync_state']!, _syncStateMeta),
      );
    } else if (isInserting) {
      context.missing(_syncStateMeta);
    }
    if (data.containsKey('logical_deleted_at')) {
      context.handle(
        _logicalDeletedAtMeta,
        logicalDeletedAt.isAcceptableOrUnknown(
          data['logical_deleted_at']!,
          _logicalDeletedAtMeta,
        ),
      );
    }
    if (data.containsKey('retry_count')) {
      context.handle(
        _retryCountMeta,
        retryCount.isAcceptableOrUnknown(data['retry_count']!, _retryCountMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => const {};
  @override
  TelemetryRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TelemetryRecord(
      eventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_id'],
      )!,
      recordType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_type'],
      )!,
      eventName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_name'],
      )!,
      eventVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}event_version'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      )!,
      traceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}trace_id'],
      )!,
      occurredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}occurred_at'],
      )!,
      feature: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}feature'],
      )!,
      severity: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}severity'],
      )!,
      appVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}app_version'],
      )!,
      buildNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}build_number'],
      )!,
      platform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}platform'],
      )!,
      properties: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}properties'],
      )!,
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
      syncState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sync_state'],
      )!,
      logicalDeletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}logical_deleted_at'],
      ),
      retryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retry_count'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $TelemetryRecordsTable createAlias(String alias) {
    return $TelemetryRecordsTable(attachedDatabase, alias);
  }
}

class TelemetryRecord extends DataClass implements Insertable<TelemetryRecord> {
  /// 服务端幂等事件 ID。
  final String eventId;

  /// 记录类型（analytics | diagnostic）。
  final String recordType;

  /// 事件名称。
  final String eventName;

  /// 事件版本。
  final int eventVersion;

  /// 设备 ID。
  final String deviceId;

  /// 会话 ID。
  final String sessionId;

  /// 追踪 ID。
  final String traceId;

  /// 发生在时间（ISO-8601 UTC）。
  final String occurredAt;

  /// 功能域。
  final String feature;

  /// 严重级别（info | warn | error | critical）。
  final String severity;

  /// 应用版本。
  final String appVersion;

  /// 构建号。
  final String buildNumber;

  /// 平台。
  final String platform;

  /// 序列化的属性 JSON。
  final String properties;

  /// 序列化的错误详情 JSON；可空。
  final String? error;

  /// 同步状态（pending | synced | rejected）。
  final String syncState;

  /// 逻辑删除时间（ISO-8601 UTC）；可空。
  final String? logicalDeletedAt;

  /// 重试次数。
  final int retryCount;

  /// 本地写入时间，用于按时间淘汰和新旧排序。
  final DateTime createdAt;
  const TelemetryRecord({
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
    required this.properties,
    this.error,
    required this.syncState,
    this.logicalDeletedAt,
    required this.retryCount,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['event_id'] = Variable<String>(eventId);
    map['record_type'] = Variable<String>(recordType);
    map['event_name'] = Variable<String>(eventName);
    map['event_version'] = Variable<int>(eventVersion);
    map['device_id'] = Variable<String>(deviceId);
    map['session_id'] = Variable<String>(sessionId);
    map['trace_id'] = Variable<String>(traceId);
    map['occurred_at'] = Variable<String>(occurredAt);
    map['feature'] = Variable<String>(feature);
    map['severity'] = Variable<String>(severity);
    map['app_version'] = Variable<String>(appVersion);
    map['build_number'] = Variable<String>(buildNumber);
    map['platform'] = Variable<String>(platform);
    map['properties'] = Variable<String>(properties);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    map['sync_state'] = Variable<String>(syncState);
    if (!nullToAbsent || logicalDeletedAt != null) {
      map['logical_deleted_at'] = Variable<String>(logicalDeletedAt);
    }
    map['retry_count'] = Variable<int>(retryCount);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  TelemetryRecordsCompanion toCompanion(bool nullToAbsent) {
    return TelemetryRecordsCompanion(
      eventId: Value(eventId),
      recordType: Value(recordType),
      eventName: Value(eventName),
      eventVersion: Value(eventVersion),
      deviceId: Value(deviceId),
      sessionId: Value(sessionId),
      traceId: Value(traceId),
      occurredAt: Value(occurredAt),
      feature: Value(feature),
      severity: Value(severity),
      appVersion: Value(appVersion),
      buildNumber: Value(buildNumber),
      platform: Value(platform),
      properties: Value(properties),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
      syncState: Value(syncState),
      logicalDeletedAt: logicalDeletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(logicalDeletedAt),
      retryCount: Value(retryCount),
      createdAt: Value(createdAt),
    );
  }

  factory TelemetryRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TelemetryRecord(
      eventId: serializer.fromJson<String>(json['eventId']),
      recordType: serializer.fromJson<String>(json['recordType']),
      eventName: serializer.fromJson<String>(json['eventName']),
      eventVersion: serializer.fromJson<int>(json['eventVersion']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      sessionId: serializer.fromJson<String>(json['sessionId']),
      traceId: serializer.fromJson<String>(json['traceId']),
      occurredAt: serializer.fromJson<String>(json['occurredAt']),
      feature: serializer.fromJson<String>(json['feature']),
      severity: serializer.fromJson<String>(json['severity']),
      appVersion: serializer.fromJson<String>(json['appVersion']),
      buildNumber: serializer.fromJson<String>(json['buildNumber']),
      platform: serializer.fromJson<String>(json['platform']),
      properties: serializer.fromJson<String>(json['properties']),
      error: serializer.fromJson<String?>(json['error']),
      syncState: serializer.fromJson<String>(json['syncState']),
      logicalDeletedAt: serializer.fromJson<String?>(json['logicalDeletedAt']),
      retryCount: serializer.fromJson<int>(json['retryCount']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'eventId': serializer.toJson<String>(eventId),
      'recordType': serializer.toJson<String>(recordType),
      'eventName': serializer.toJson<String>(eventName),
      'eventVersion': serializer.toJson<int>(eventVersion),
      'deviceId': serializer.toJson<String>(deviceId),
      'sessionId': serializer.toJson<String>(sessionId),
      'traceId': serializer.toJson<String>(traceId),
      'occurredAt': serializer.toJson<String>(occurredAt),
      'feature': serializer.toJson<String>(feature),
      'severity': serializer.toJson<String>(severity),
      'appVersion': serializer.toJson<String>(appVersion),
      'buildNumber': serializer.toJson<String>(buildNumber),
      'platform': serializer.toJson<String>(platform),
      'properties': serializer.toJson<String>(properties),
      'error': serializer.toJson<String?>(error),
      'syncState': serializer.toJson<String>(syncState),
      'logicalDeletedAt': serializer.toJson<String?>(logicalDeletedAt),
      'retryCount': serializer.toJson<int>(retryCount),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  TelemetryRecord copyWith({
    String? eventId,
    String? recordType,
    String? eventName,
    int? eventVersion,
    String? deviceId,
    String? sessionId,
    String? traceId,
    String? occurredAt,
    String? feature,
    String? severity,
    String? appVersion,
    String? buildNumber,
    String? platform,
    String? properties,
    Value<String?> error = const Value.absent(),
    String? syncState,
    Value<String?> logicalDeletedAt = const Value.absent(),
    int? retryCount,
    DateTime? createdAt,
  }) => TelemetryRecord(
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
    error: error.present ? error.value : this.error,
    syncState: syncState ?? this.syncState,
    logicalDeletedAt: logicalDeletedAt.present
        ? logicalDeletedAt.value
        : this.logicalDeletedAt,
    retryCount: retryCount ?? this.retryCount,
    createdAt: createdAt ?? this.createdAt,
  );
  TelemetryRecord copyWithCompanion(TelemetryRecordsCompanion data) {
    return TelemetryRecord(
      eventId: data.eventId.present ? data.eventId.value : this.eventId,
      recordType: data.recordType.present
          ? data.recordType.value
          : this.recordType,
      eventName: data.eventName.present ? data.eventName.value : this.eventName,
      eventVersion: data.eventVersion.present
          ? data.eventVersion.value
          : this.eventVersion,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      traceId: data.traceId.present ? data.traceId.value : this.traceId,
      occurredAt: data.occurredAt.present
          ? data.occurredAt.value
          : this.occurredAt,
      feature: data.feature.present ? data.feature.value : this.feature,
      severity: data.severity.present ? data.severity.value : this.severity,
      appVersion: data.appVersion.present
          ? data.appVersion.value
          : this.appVersion,
      buildNumber: data.buildNumber.present
          ? data.buildNumber.value
          : this.buildNumber,
      platform: data.platform.present ? data.platform.value : this.platform,
      properties: data.properties.present
          ? data.properties.value
          : this.properties,
      error: data.error.present ? data.error.value : this.error,
      syncState: data.syncState.present ? data.syncState.value : this.syncState,
      logicalDeletedAt: data.logicalDeletedAt.present
          ? data.logicalDeletedAt.value
          : this.logicalDeletedAt,
      retryCount: data.retryCount.present
          ? data.retryCount.value
          : this.retryCount,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TelemetryRecord(')
          ..write('eventId: $eventId, ')
          ..write('recordType: $recordType, ')
          ..write('eventName: $eventName, ')
          ..write('eventVersion: $eventVersion, ')
          ..write('deviceId: $deviceId, ')
          ..write('sessionId: $sessionId, ')
          ..write('traceId: $traceId, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('feature: $feature, ')
          ..write('severity: $severity, ')
          ..write('appVersion: $appVersion, ')
          ..write('buildNumber: $buildNumber, ')
          ..write('platform: $platform, ')
          ..write('properties: $properties, ')
          ..write('error: $error, ')
          ..write('syncState: $syncState, ')
          ..write('logicalDeletedAt: $logicalDeletedAt, ')
          ..write('retryCount: $retryCount, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    eventId,
    recordType,
    eventName,
    eventVersion,
    deviceId,
    sessionId,
    traceId,
    occurredAt,
    feature,
    severity,
    appVersion,
    buildNumber,
    platform,
    properties,
    error,
    syncState,
    logicalDeletedAt,
    retryCount,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TelemetryRecord &&
          other.eventId == this.eventId &&
          other.recordType == this.recordType &&
          other.eventName == this.eventName &&
          other.eventVersion == this.eventVersion &&
          other.deviceId == this.deviceId &&
          other.sessionId == this.sessionId &&
          other.traceId == this.traceId &&
          other.occurredAt == this.occurredAt &&
          other.feature == this.feature &&
          other.severity == this.severity &&
          other.appVersion == this.appVersion &&
          other.buildNumber == this.buildNumber &&
          other.platform == this.platform &&
          other.properties == this.properties &&
          other.error == this.error &&
          other.syncState == this.syncState &&
          other.logicalDeletedAt == this.logicalDeletedAt &&
          other.retryCount == this.retryCount &&
          other.createdAt == this.createdAt);
}

class TelemetryRecordsCompanion extends UpdateCompanion<TelemetryRecord> {
  final Value<String> eventId;
  final Value<String> recordType;
  final Value<String> eventName;
  final Value<int> eventVersion;
  final Value<String> deviceId;
  final Value<String> sessionId;
  final Value<String> traceId;
  final Value<String> occurredAt;
  final Value<String> feature;
  final Value<String> severity;
  final Value<String> appVersion;
  final Value<String> buildNumber;
  final Value<String> platform;
  final Value<String> properties;
  final Value<String?> error;
  final Value<String> syncState;
  final Value<String?> logicalDeletedAt;
  final Value<int> retryCount;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const TelemetryRecordsCompanion({
    this.eventId = const Value.absent(),
    this.recordType = const Value.absent(),
    this.eventName = const Value.absent(),
    this.eventVersion = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.traceId = const Value.absent(),
    this.occurredAt = const Value.absent(),
    this.feature = const Value.absent(),
    this.severity = const Value.absent(),
    this.appVersion = const Value.absent(),
    this.buildNumber = const Value.absent(),
    this.platform = const Value.absent(),
    this.properties = const Value.absent(),
    this.error = const Value.absent(),
    this.syncState = const Value.absent(),
    this.logicalDeletedAt = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TelemetryRecordsCompanion.insert({
    required String eventId,
    required String recordType,
    required String eventName,
    required int eventVersion,
    required String deviceId,
    required String sessionId,
    required String traceId,
    required String occurredAt,
    required String feature,
    required String severity,
    required String appVersion,
    required String buildNumber,
    required String platform,
    required String properties,
    this.error = const Value.absent(),
    required String syncState,
    this.logicalDeletedAt = const Value.absent(),
    this.retryCount = const Value.absent(),
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : eventId = Value(eventId),
       recordType = Value(recordType),
       eventName = Value(eventName),
       eventVersion = Value(eventVersion),
       deviceId = Value(deviceId),
       sessionId = Value(sessionId),
       traceId = Value(traceId),
       occurredAt = Value(occurredAt),
       feature = Value(feature),
       severity = Value(severity),
       appVersion = Value(appVersion),
       buildNumber = Value(buildNumber),
       platform = Value(platform),
       properties = Value(properties),
       syncState = Value(syncState),
       createdAt = Value(createdAt);
  static Insertable<TelemetryRecord> custom({
    Expression<String>? eventId,
    Expression<String>? recordType,
    Expression<String>? eventName,
    Expression<int>? eventVersion,
    Expression<String>? deviceId,
    Expression<String>? sessionId,
    Expression<String>? traceId,
    Expression<String>? occurredAt,
    Expression<String>? feature,
    Expression<String>? severity,
    Expression<String>? appVersion,
    Expression<String>? buildNumber,
    Expression<String>? platform,
    Expression<String>? properties,
    Expression<String>? error,
    Expression<String>? syncState,
    Expression<String>? logicalDeletedAt,
    Expression<int>? retryCount,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (eventId != null) 'event_id': eventId,
      if (recordType != null) 'record_type': recordType,
      if (eventName != null) 'event_name': eventName,
      if (eventVersion != null) 'event_version': eventVersion,
      if (deviceId != null) 'device_id': deviceId,
      if (sessionId != null) 'session_id': sessionId,
      if (traceId != null) 'trace_id': traceId,
      if (occurredAt != null) 'occurred_at': occurredAt,
      if (feature != null) 'feature': feature,
      if (severity != null) 'severity': severity,
      if (appVersion != null) 'app_version': appVersion,
      if (buildNumber != null) 'build_number': buildNumber,
      if (platform != null) 'platform': platform,
      if (properties != null) 'properties': properties,
      if (error != null) 'error': error,
      if (syncState != null) 'sync_state': syncState,
      if (logicalDeletedAt != null) 'logical_deleted_at': logicalDeletedAt,
      if (retryCount != null) 'retry_count': retryCount,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TelemetryRecordsCompanion copyWith({
    Value<String>? eventId,
    Value<String>? recordType,
    Value<String>? eventName,
    Value<int>? eventVersion,
    Value<String>? deviceId,
    Value<String>? sessionId,
    Value<String>? traceId,
    Value<String>? occurredAt,
    Value<String>? feature,
    Value<String>? severity,
    Value<String>? appVersion,
    Value<String>? buildNumber,
    Value<String>? platform,
    Value<String>? properties,
    Value<String?>? error,
    Value<String>? syncState,
    Value<String?>? logicalDeletedAt,
    Value<int>? retryCount,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return TelemetryRecordsCompanion(
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
      logicalDeletedAt: logicalDeletedAt ?? this.logicalDeletedAt,
      retryCount: retryCount ?? this.retryCount,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (eventId.present) {
      map['event_id'] = Variable<String>(eventId.value);
    }
    if (recordType.present) {
      map['record_type'] = Variable<String>(recordType.value);
    }
    if (eventName.present) {
      map['event_name'] = Variable<String>(eventName.value);
    }
    if (eventVersion.present) {
      map['event_version'] = Variable<int>(eventVersion.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (traceId.present) {
      map['trace_id'] = Variable<String>(traceId.value);
    }
    if (occurredAt.present) {
      map['occurred_at'] = Variable<String>(occurredAt.value);
    }
    if (feature.present) {
      map['feature'] = Variable<String>(feature.value);
    }
    if (severity.present) {
      map['severity'] = Variable<String>(severity.value);
    }
    if (appVersion.present) {
      map['app_version'] = Variable<String>(appVersion.value);
    }
    if (buildNumber.present) {
      map['build_number'] = Variable<String>(buildNumber.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (properties.present) {
      map['properties'] = Variable<String>(properties.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (syncState.present) {
      map['sync_state'] = Variable<String>(syncState.value);
    }
    if (logicalDeletedAt.present) {
      map['logical_deleted_at'] = Variable<String>(logicalDeletedAt.value);
    }
    if (retryCount.present) {
      map['retry_count'] = Variable<int>(retryCount.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TelemetryRecordsCompanion(')
          ..write('eventId: $eventId, ')
          ..write('recordType: $recordType, ')
          ..write('eventName: $eventName, ')
          ..write('eventVersion: $eventVersion, ')
          ..write('deviceId: $deviceId, ')
          ..write('sessionId: $sessionId, ')
          ..write('traceId: $traceId, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('feature: $feature, ')
          ..write('severity: $severity, ')
          ..write('appVersion: $appVersion, ')
          ..write('buildNumber: $buildNumber, ')
          ..write('platform: $platform, ')
          ..write('properties: $properties, ')
          ..write('error: $error, ')
          ..write('syncState: $syncState, ')
          ..write('logicalDeletedAt: $logicalDeletedAt, ')
          ..write('retryCount: $retryCount, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$TelemetryDatabase extends GeneratedDatabase {
  _$TelemetryDatabase(QueryExecutor e) : super(e);
  $TelemetryDatabaseManager get managers => $TelemetryDatabaseManager(this);
  late final $TelemetryRecordsTable telemetryRecords = $TelemetryRecordsTable(
    this,
  );
  late final TelemetryRecordsDao telemetryRecordsDao = TelemetryRecordsDao(
    this as TelemetryDatabase,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [telemetryRecords];
}

typedef $$TelemetryRecordsTableCreateCompanionBuilder =
    TelemetryRecordsCompanion Function({
      required String eventId,
      required String recordType,
      required String eventName,
      required int eventVersion,
      required String deviceId,
      required String sessionId,
      required String traceId,
      required String occurredAt,
      required String feature,
      required String severity,
      required String appVersion,
      required String buildNumber,
      required String platform,
      required String properties,
      Value<String?> error,
      required String syncState,
      Value<String?> logicalDeletedAt,
      Value<int> retryCount,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$TelemetryRecordsTableUpdateCompanionBuilder =
    TelemetryRecordsCompanion Function({
      Value<String> eventId,
      Value<String> recordType,
      Value<String> eventName,
      Value<int> eventVersion,
      Value<String> deviceId,
      Value<String> sessionId,
      Value<String> traceId,
      Value<String> occurredAt,
      Value<String> feature,
      Value<String> severity,
      Value<String> appVersion,
      Value<String> buildNumber,
      Value<String> platform,
      Value<String> properties,
      Value<String?> error,
      Value<String> syncState,
      Value<String?> logicalDeletedAt,
      Value<int> retryCount,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

class $$TelemetryRecordsTableFilterComposer
    extends Composer<_$TelemetryDatabase, $TelemetryRecordsTable> {
  $$TelemetryRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordType => $composableBuilder(
    column: $table.recordType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get eventName => $composableBuilder(
    column: $table.eventName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get eventVersion => $composableBuilder(
    column: $table.eventVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get traceId => $composableBuilder(
    column: $table.traceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get feature => $composableBuilder(
    column: $table.feature,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get appVersion => $composableBuilder(
    column: $table.appVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get buildNumber => $composableBuilder(
    column: $table.buildNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get properties => $composableBuilder(
    column: $table.properties,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get logicalDeletedAt => $composableBuilder(
    column: $table.logicalDeletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TelemetryRecordsTableOrderingComposer
    extends Composer<_$TelemetryDatabase, $TelemetryRecordsTable> {
  $$TelemetryRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordType => $composableBuilder(
    column: $table.recordType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get eventName => $composableBuilder(
    column: $table.eventName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get eventVersion => $composableBuilder(
    column: $table.eventVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get traceId => $composableBuilder(
    column: $table.traceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get feature => $composableBuilder(
    column: $table.feature,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get appVersion => $composableBuilder(
    column: $table.appVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get buildNumber => $composableBuilder(
    column: $table.buildNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get properties => $composableBuilder(
    column: $table.properties,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get logicalDeletedAt => $composableBuilder(
    column: $table.logicalDeletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TelemetryRecordsTableAnnotationComposer
    extends Composer<_$TelemetryDatabase, $TelemetryRecordsTable> {
  $$TelemetryRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get eventId =>
      $composableBuilder(column: $table.eventId, builder: (column) => column);

  GeneratedColumn<String> get recordType => $composableBuilder(
    column: $table.recordType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get eventName =>
      $composableBuilder(column: $table.eventName, builder: (column) => column);

  GeneratedColumn<int> get eventVersion => $composableBuilder(
    column: $table.eventVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get traceId =>
      $composableBuilder(column: $table.traceId, builder: (column) => column);

  GeneratedColumn<String> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get feature =>
      $composableBuilder(column: $table.feature, builder: (column) => column);

  GeneratedColumn<String> get severity =>
      $composableBuilder(column: $table.severity, builder: (column) => column);

  GeneratedColumn<String> get appVersion => $composableBuilder(
    column: $table.appVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get buildNumber => $composableBuilder(
    column: $table.buildNumber,
    builder: (column) => column,
  );

  GeneratedColumn<String> get platform =>
      $composableBuilder(column: $table.platform, builder: (column) => column);

  GeneratedColumn<String> get properties => $composableBuilder(
    column: $table.properties,
    builder: (column) => column,
  );

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<String> get syncState =>
      $composableBuilder(column: $table.syncState, builder: (column) => column);

  GeneratedColumn<String> get logicalDeletedAt => $composableBuilder(
    column: $table.logicalDeletedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$TelemetryRecordsTableTableManager
    extends
        RootTableManager<
          _$TelemetryDatabase,
          $TelemetryRecordsTable,
          TelemetryRecord,
          $$TelemetryRecordsTableFilterComposer,
          $$TelemetryRecordsTableOrderingComposer,
          $$TelemetryRecordsTableAnnotationComposer,
          $$TelemetryRecordsTableCreateCompanionBuilder,
          $$TelemetryRecordsTableUpdateCompanionBuilder,
          (
            TelemetryRecord,
            BaseReferences<
              _$TelemetryDatabase,
              $TelemetryRecordsTable,
              TelemetryRecord
            >,
          ),
          TelemetryRecord,
          PrefetchHooks Function()
        > {
  $$TelemetryRecordsTableTableManager(
    _$TelemetryDatabase db,
    $TelemetryRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TelemetryRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TelemetryRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TelemetryRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> eventId = const Value.absent(),
                Value<String> recordType = const Value.absent(),
                Value<String> eventName = const Value.absent(),
                Value<int> eventVersion = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<String> sessionId = const Value.absent(),
                Value<String> traceId = const Value.absent(),
                Value<String> occurredAt = const Value.absent(),
                Value<String> feature = const Value.absent(),
                Value<String> severity = const Value.absent(),
                Value<String> appVersion = const Value.absent(),
                Value<String> buildNumber = const Value.absent(),
                Value<String> platform = const Value.absent(),
                Value<String> properties = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<String> syncState = const Value.absent(),
                Value<String?> logicalDeletedAt = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TelemetryRecordsCompanion(
                eventId: eventId,
                recordType: recordType,
                eventName: eventName,
                eventVersion: eventVersion,
                deviceId: deviceId,
                sessionId: sessionId,
                traceId: traceId,
                occurredAt: occurredAt,
                feature: feature,
                severity: severity,
                appVersion: appVersion,
                buildNumber: buildNumber,
                platform: platform,
                properties: properties,
                error: error,
                syncState: syncState,
                logicalDeletedAt: logicalDeletedAt,
                retryCount: retryCount,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String eventId,
                required String recordType,
                required String eventName,
                required int eventVersion,
                required String deviceId,
                required String sessionId,
                required String traceId,
                required String occurredAt,
                required String feature,
                required String severity,
                required String appVersion,
                required String buildNumber,
                required String platform,
                required String properties,
                Value<String?> error = const Value.absent(),
                required String syncState,
                Value<String?> logicalDeletedAt = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => TelemetryRecordsCompanion.insert(
                eventId: eventId,
                recordType: recordType,
                eventName: eventName,
                eventVersion: eventVersion,
                deviceId: deviceId,
                sessionId: sessionId,
                traceId: traceId,
                occurredAt: occurredAt,
                feature: feature,
                severity: severity,
                appVersion: appVersion,
                buildNumber: buildNumber,
                platform: platform,
                properties: properties,
                error: error,
                syncState: syncState,
                logicalDeletedAt: logicalDeletedAt,
                retryCount: retryCount,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TelemetryRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$TelemetryDatabase,
      $TelemetryRecordsTable,
      TelemetryRecord,
      $$TelemetryRecordsTableFilterComposer,
      $$TelemetryRecordsTableOrderingComposer,
      $$TelemetryRecordsTableAnnotationComposer,
      $$TelemetryRecordsTableCreateCompanionBuilder,
      $$TelemetryRecordsTableUpdateCompanionBuilder,
      (
        TelemetryRecord,
        BaseReferences<
          _$TelemetryDatabase,
          $TelemetryRecordsTable,
          TelemetryRecord
        >,
      ),
      TelemetryRecord,
      PrefetchHooks Function()
    >;

class $TelemetryDatabaseManager {
  final _$TelemetryDatabase _db;
  $TelemetryDatabaseManager(this._db);
  $$TelemetryRecordsTableTableManager get telemetryRecords =>
      $$TelemetryRecordsTableTableManager(_db, _db.telemetryRecords);
}

mixin _$TelemetryRecordsDaoMixin on DatabaseAccessor<TelemetryDatabase> {
  $TelemetryRecordsTable get telemetryRecords =>
      attachedDatabase.telemetryRecords;
  TelemetryRecordsDaoManager get managers => TelemetryRecordsDaoManager(this);
}

class TelemetryRecordsDaoManager {
  final _$TelemetryRecordsDaoMixin _db;
  TelemetryRecordsDaoManager(this._db);
  $$TelemetryRecordsTableTableManager get telemetryRecords =>
      $$TelemetryRecordsTableTableManager(
        _db.attachedDatabase,
        _db.telemetryRecords,
      );
}
