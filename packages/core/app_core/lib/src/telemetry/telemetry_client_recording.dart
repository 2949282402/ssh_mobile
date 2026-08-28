part of 'telemetry_client.dart';

mixin _TelemetryClientRecording on _TelemetryClientBase {
  /// Records an event using generated contract metadata and schema allowlists.
  Future<bool> record({
    required TelemetryEventDefinition event,
    Map<String, dynamic> properties = const {},
    TelemetryErrorCodeDefinition? errorCode,
    String? errorMessage,
    String? stackTrace,
    String? sessionId,
    String? traceId,
  }) {
    if (_isDisposed) return Future<bool>.value(false);
    final previous = _recordQueue;
    final queuedProperties = Map<String, dynamic>.from(properties);
    late final Future<bool> operation;
    operation = previous.then<bool>(
      (_) => _recordNow(
        event: event,
        properties: queuedProperties,
        errorCode: errorCode,
        errorMessage: errorMessage,
        stackTrace: stackTrace,
        sessionId: sessionId,
        traceId: traceId,
      ),
    );
    _recordQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<bool> _recordNow({
    required TelemetryEventDefinition event,
    required Map<String, dynamic> properties,
    required TelemetryErrorCodeDefinition? errorCode,
    required String? errorMessage,
    required String? stackTrace,
    required String? sessionId,
    required String? traceId,
  }) async {
    // The public record gate runs before enqueueing. Accepted queued writes
    // still drain after dispose marks the client closed.
    final safeDeviceId = redactor.sanitizeIdentifier(config.deviceId);
    final safeAppVersion = _sanitizeConfiguredMetadata(config.appVersion);
    final safeBuildNumber = _sanitizeConfiguredMetadata(config.buildNumber);
    final safePlatform = _sanitizeConfiguredMetadata(config.platform);
    final safeReleaseChannel = _sanitizeConfiguredMetadata(
      config.releaseChannel,
    );
    if (safeDeviceId != config.deviceId ||
        safeAppVersion == null ||
        safeBuildNumber == null ||
        safePlatform == null ||
        safeReleaseChannel == null) {
      return false;
    }

    final now = _now();
    final eventId = 'evt_${_telemetryUuid.v4()}';
    final safeProperties = redactor.sanitizeProperties(event, properties);
    if (safeProperties == null) return false;

    final safeSessionId = redactor.sanitizeIdentifier(
      sessionId ?? this.sessionId,
    );
    final safeTraceId = redactor.sanitizeIdentifier(traceId ?? _newTraceId());
    if (safeSessionId == null || safeTraceId == null) return false;

    final errorDetail = errorCode == null
        ? null
        : TelemetryErrorDetail(
            errorCode: errorCode.code,
            category: errorCode.category,
            terminalFailure: errorCode.terminalFailure,
            message: redactor.sanitizeExceptionText(errorMessage),
            stackTrace: redactor.sanitizeStackTrace(stackTrace),
          );
    final record = TelemetryEventRecord(
      eventId: eventId,
      recordType: event.recordType,
      eventName: event.name,
      eventVersion: event.version,
      deviceId: safeDeviceId!,
      sessionId: safeSessionId,
      traceId: safeTraceId,
      occurredAt: now,
      feature: event.feature,
      severity: event.severity,
      appVersion: safeAppVersion,
      buildNumber: safeBuildNumber,
      platform: safePlatform,
      releaseChannel: safeReleaseChannel,
      properties: safeProperties,
      error: errorDetail,
    );

    if (!catalog.isValidRecord(record)) return false;

    try {
      await storage.insertRecord(record);
    } on Object {
      // Fire-and-forget producers receive a contained false result instead of
      // an unhandled zone error; no durable row exists after this failure.
      _recordStorageFailure();
      return false;
    }

    final isHighPriorityError =
        event.severity == TelemetrySeverity.error ||
        event.severity == TelemetrySeverity.critical;
    if (isHighPriorityError && activePolicy.triggerHighPriorityError) {
      unawaited(_requestUpload());
    } else {
      try {
        final pending = await storage.fetchPendingBatch(
          activePolicy.batchSizeThreshold,
        );
        if (pending.length >= activePolicy.batchSizeThreshold) {
          unawaited(_requestUpload());
        }
      } on Object {
        // The accepted record remains durable; the next scheduled/background
        // flush can retry the threshold read.
        _recordStorageFailure();
      }
    }

    return true;
  }

  static const _persistedRecordRejectedReason =
      'Telemetry record failed local validation';

  /// Re-applies privacy and contract boundaries to rows read from storage.
  @override
  Future<List<TelemetryEventRecord>> _preparePersistedRecords(
    Iterable<TelemetryEventRecord> records,
  ) async {
    final valid = <TelemetryEventRecord>[];
    final rejected = <TelemetryAckResult>[];
    for (final record in records) {
      final safe = _sanitizePersistedRecord(record);
      if (safe == null) {
        rejected.add(
          TelemetryAckResult(
            eventId: record.eventId,
            status: 'rejected',
            reason: _persistedRecordRejectedReason,
          ),
        );
      } else {
        valid.add(safe);
      }
    }

    if (rejected.isNotEmpty) await storage.applyAckResults(rejected);
    return valid;
  }

  TelemetryEventRecord? _sanitizePersistedRecord(TelemetryEventRecord record) {
    final event = catalog.eventDefinition(record.eventName);
    final eventId = redactor.sanitizeIdentifier(record.eventId);
    final deviceId = redactor.sanitizeIdentifier(record.deviceId);
    final sessionId = redactor.sanitizeIdentifier(record.sessionId);
    final traceId = redactor.sanitizeIdentifier(record.traceId);
    if (event == null ||
        eventId == null ||
        deviceId == null ||
        deviceId != config.deviceId ||
        sessionId == null ||
        traceId == null ||
        !_isSafePersistedMetadata(record.appVersion) ||
        !_isSafePersistedMetadata(record.buildNumber) ||
        !_isSafePersistedMetadata(record.platform) ||
        (record.releaseChannel != null &&
            !_isSafePersistedMetadata(record.releaseChannel!))) {
      return null;
    }

    final properties = redactor.sanitizeProperties(event, record.properties);
    if (properties == null) return null;

    TelemetryErrorDetail? error;
    final persistedError = record.error;
    if (persistedError != null) {
      final errorDefinition = catalog.errorDefinition(persistedError.errorCode);
      if (errorDefinition == null ||
          persistedError.category != errorDefinition.category ||
          persistedError.terminalFailure != errorDefinition.terminalFailure) {
        return null;
      }
      error = TelemetryErrorDetail(
        errorCode: errorDefinition.code,
        category: errorDefinition.category,
        terminalFailure: errorDefinition.terminalFailure,
        message: redactor.sanitizeExceptionText(persistedError.message),
        stackTrace: redactor.sanitizeStackTrace(persistedError.stackTrace),
      );
    }

    final sanitized = TelemetryEventRecord(
      eventId: eventId,
      recordType: record.recordType,
      eventName: record.eventName,
      eventVersion: record.eventVersion,
      deviceId: deviceId,
      sessionId: sessionId,
      traceId: traceId,
      occurredAt: record.occurredAt,
      feature: record.feature,
      severity: record.severity,
      appVersion: record.appVersion,
      buildNumber: record.buildNumber,
      platform: record.platform,
      releaseChannel: record.releaseChannel,
      properties: properties,
      error: error,
      syncState: record.syncState,
      logicalDeletedAt: record.logicalDeletedAt,
      retryCount: record.retryCount,
    );
    return catalog.isValidRecord(sanitized) ? sanitized : null;
  }
}
