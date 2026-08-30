part of 'telemetry_client.dart';

const int _telemetryMinRetryDelayMs = 1000;
const int _telemetryMaxRetryDelayMs = 60000;

mixin _TelemetryClientUpload on _TelemetryClientBase {
  /// Flushes pending records through one shared upload drain.
  Future<void> flush() => _requestUpload();

  @override
  Future<void> _requestUpload() {
    if (_isDisposed || !activePolicy.uploadEnabled) {
      return Future<void>.value();
    }

    _uploadRequested = true;
    final inFlight = _uploadFuture;
    if (inFlight != null) return inFlight;

    // An explicit trigger supersedes a waiting retry. A trigger received while
    // the failed request is in flight remains represented by that drain.
    _cancelRetryTimer();
    _isUploading = true;
    final operation = _drainUploadRequests();
    late final Future<void> tracked;
    tracked = operation.whenComplete(() => _completeUpload(tracked));
    _uploadFuture = tracked;
    return tracked;
  }

  Future<void> _drainUploadRequests() async {
    await ready;
    if (_isDisposed || !activePolicy.uploadEnabled) {
      _uploadRequested = false;
      return;
    }
    while (_uploadRequested) {
      _uploadRequested = false;
      if (_isDisposed || !activePolicy.uploadEnabled) return;
      await _flushWithToken();

      final retryWait = _retryWaitCompleter?.future;
      if (_retryTimer != null && _uploadRequested && retryWait != null) {
        await retryWait;
      }
      if (_retryTimer != null) return;
    }
  }

  @override
  void _completeUpload(Future<void> operation) {
    if (!identical(_uploadFuture, operation)) return;
    _uploadFuture = null;
    _isUploading = false;
    if (_uploadRequested &&
        _retryTimer == null &&
        !_isDisposed &&
        activePolicy.uploadEnabled) {
      unawaited(_requestUpload());
    }
  }

  Future<void> _flushWithToken() async {
    final batchSize = activePolicy.maxBatchSize > 0
        ? activePolicy.maxBatchSize
        : 50;
    late final List<TelemetryEventRecord> persisted;
    try {
      persisted = await storage.fetchPendingBatch(batchSize);
    } on Object {
      _recordStorageFailure();
      return;
    }
    late final List<TelemetryEventRecord> pending;
    try {
      pending = await _preparePersistedRecords(persisted);
    } on Object {
      // Quarantine is part of the local durability boundary; leave rows
      // pending if it fails.
      _recordStorageFailure();
      return;
    }
    if (pending.isEmpty) return;

    try {
      await _ensureAuthenticated();
    } catch (e) {
      _lastSyncError = _describeError(e);
      await _handleUploadFailure(pending, _asUploadException(e));
      return;
    }
    if (!_hasValidToken) {
      await _handleAuthenticationFailure(pending);
      return;
    }

    try {
      final result = await transport.uploadBatch(
        baseUrl: config.baseUrl,
        authToken: _authToken!,
        deviceId: config.deviceId,
        records: pending,
      );
      if (!await _applyUploadResult(result, records: pending)) return;
      _cancelRetryTimer();
      _lastSyncTime = _now();
      _lastSyncError = null;
    } on TelemetryUploadException catch (e) {
      if (e.isUnauthorized) {
        // Clear the stale token and re-authenticate once for this batch.
        _clearAuthToken();
        try {
          await _ensureAuthenticated();
        } catch (authError) {
          _lastSyncError = _describeError(authError);
          await _handleUploadFailure(pending, _asUploadException(authError));
          return;
        }
        if (!_hasValidToken) {
          await _handleAuthenticationFailure(pending);
          return;
        }
        try {
          final retried = await transport.uploadBatch(
            baseUrl: config.baseUrl,
            authToken: _authToken!,
            deviceId: config.deviceId,
            records: pending,
          );
          if (!await _applyUploadResult(retried, records: pending)) return;
          _cancelRetryTimer();
          _lastSyncTime = _now();
          _lastSyncError = null;
        } on TelemetryUploadException catch (retryError) {
          if (retryError.isUnauthorized) _clearAuthToken();
          await _handleUploadFailure(pending, retryError);
        }
      } else if (e.isPermanentClientError) {
        final results = [
          for (final r in pending)
            TelemetryAckResult(
              eventId: r.eventId,
              status: 'rejected',
              reason:
                  _safeTelemetryErrorCode(e.errorCode) ??
                  'Telemetry upload rejected',
            ),
        ];
        try {
          await storage.applyAckResults(results);
        } on Object {
          _recordStorageFailure();
          return;
        }
        _lastSyncError = _describeError(e);
      } else {
        await _handleUploadFailure(pending, e);
      }
    } catch (e) {
      await _handleUploadFailure(
        pending,
        TelemetryUploadException(_describeError(e)),
      );
    }
  }

  Future<bool> _applyUploadResult(
    TelemetryBatchUploadResult result, {
    required List<TelemetryEventRecord> records,
    bool purge = true,
  }) async {
    final expectedIds = records.map((record) => record.eventId).toSet();
    final acknowledgedIds = <String>{};
    final validAcks = <TelemetryAckResult>[];
    var invalidResponse = expectedIds.length != records.length;
    for (final ack in result.ackResults) {
      if (!_isKnownTelemetryAckStatus(ack.status) ||
          !expectedIds.contains(ack.eventId) ||
          !acknowledgedIds.add(ack.eventId)) {
        invalidResponse = true;
        continue;
      }
      validAcks.add(ack);
    }

    const invalidAckError = TelemetryUploadException(
      'Telemetry upload response is invalid',
      statusCode: 502,
      errorCode: 'INVALID_RESPONSE',
    );
    if (invalidResponse) {
      // Ambiguous ACKs fail closed; do not advance a valid subset.
      await _handleUploadFailure(records, invalidAckError);
      return false;
    }

    final unacknowledged = records
        .where((record) => !acknowledgedIds.contains(record.eventId))
        .toList();
    try {
      if (validAcks.isNotEmpty) await storage.applyAckResults(validAcks);
      if (unacknowledged.isNotEmpty) {
        await _handleUploadFailure(unacknowledged, invalidAckError);
        return false;
      }
      if (purge) {
        await storage.purgeOldSyncedRecords(
          targetCapacity: activePolicy.clientMaxLocalRecords,
        );
      }
      return true;
    } on Object {
      // Without a durable local ACK, rows remain pending for idempotent replay.
      _recordStorageFailure();
      return false;
    }
  }

  Future<bool> _handleUploadFailure(
    List<TelemetryEventRecord> records,
    TelemetryUploadException error,
  ) async {
    _lastSyncError = _describeError(error);
    if (error.isPermanentClientError) return false;
    try {
      await storage.applyRetryCount(
        records.map((r) => r.eventId).toList(),
        increment: 1,
      );
    } on Object {
      _recordStorageFailure();
      return false;
    }
    _scheduleBackoffRetry(records, error);
    return true;
  }

  /// Treats an unusable successful auth response as a transient auth failure.
  /// The safe user-facing diagnostic remains stable while the row receives the
  /// same durable retry bookkeeping as transport-level auth failures.
  Future<void> _handleAuthenticationFailure(
    List<TelemetryEventRecord> records,
  ) async {
    final retryScheduled = await _handleUploadFailure(
      records,
      const TelemetryUploadException('Device authentication failed'),
    );
    if (retryScheduled) _lastSyncError = 'Device authentication failed';
  }

  /// 429 prefers Retry-After; other failures use bounded exponential jitter.
  void _scheduleBackoffRetry(
    List<TelemetryEventRecord> records,
    TelemetryUploadException error,
  ) {
    int delayMs;
    if (error.retryAfterSeconds != null && error.retryAfterSeconds! > 0) {
      delayMs =
          min(error.retryAfterSeconds!, _telemetryMaxRetryDelayMs ~/ 1000) *
          1000;
    } else {
      final maxRetries = records.fold<int>(
        0,
        (acc, r) => max(acc, r.retryCount),
      );
      final attempt = min(max(0, maxRetries), 6) + 1;
      final exponential = min(
        1000 * (1 << (attempt - 1)),
        _telemetryMaxRetryDelayMs,
      );
      final jitterRange = exponential ~/ 5;
      final jitter =
          (_random.nextDouble() * (jitterRange * 2 + 1)).floor() - jitterRange;
      delayMs = (exponential + jitter).clamp(
        _telemetryMinRetryDelayMs,
        _telemetryMaxRetryDelayMs,
      );
    }

    if (_isDisposed) return;
    _cancelRetryTimer();
    _retryWaitCompleter = Completer<void>();
    _retryTimer = _timerFactory.schedule(Duration(milliseconds: delayMs), () {
      _retryTimer = null;
      final retryWait = _retryWaitCompleter;
      _retryWaitCompleter = null;
      if (retryWait != null && !retryWait.isCompleted) retryWait.complete();
      if (_isDisposed) return Future<void>.value();
      if (_uploadFuture == null) return _requestUpload();
      return Future<void>.value();
    });
  }

  @override
  void _cancelRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final retryWait = _retryWaitCompleter;
    _retryWaitCompleter = null;
    if (retryWait != null && !retryWait.isCompleted) retryWait.complete();
  }

  /// Replays every local row with its original event/session/trace identity.
  Future<int> replayAllLocalRecords() {
    if (_isDisposed || _isUploading) return Future<int>.value(0);
    _cancelRetryTimer();
    _isUploading = true;
    final operation = _replayAndDrainFollowUps();
    final trackedOperation = operation.then<void>((_) {});
    _uploadFuture = trackedOperation;
    return operation.whenComplete(() => _completeUpload(trackedOperation));
  }

  Future<int> _replayAndDrainFollowUps() async {
    final replayed = await _replayAllLocalRecords();
    // Keep a concurrent normal flush on the same completion future.
    await _drainUploadRequests();
    return replayed;
  }

  Future<int> _replayAllLocalRecords() async {
    try {
      await ready;
      if (_isDisposed || !activePolicy.uploadEnabled) return 0;
      final allRecords = await storage.fetchAllForReplay();
      // Rejected rows have an explicit manual-retry operation. Keeping them
      // out of the broad replay prevents a historical replay from silently
      // changing the meaning of a permanent server rejection.
      final replayableRecords = allRecords
          .where(
            (record) =>
                record.syncState == TelemetrySyncState.pending ||
                record.syncState == TelemetrySyncState.synced,
          )
          .toList();
      if (replayableRecords.isEmpty) return 0;

      // Pending rows retain the normal persisted-record quarantine semantics.
      // A historical synced row must never be changed to rejected merely
      // because a current contract or privacy rule no longer accepts it.
      final pendingSource = replayableRecords.where(
        (record) => record.syncState == TelemetrySyncState.pending,
      );
      final pending = await _preparePersistedRecords(pendingSource);
      final preparedById = <String, TelemetryEventRecord>{
        for (final record in pending) record.eventId: record,
      };
      for (final record in replayableRecords.where(
        (record) => record.syncState == TelemetrySyncState.synced,
      )) {
        final safe = _sanitizePersistedRecord(record);
        if (safe == null) {
          // Do not quarantine an originally synced row. It remains available
          // for a future replay after a compatible catalog is restored.
          _lastSyncError = _persistedRecordRejectedReason;
          continue;
        }
        preparedById[safe.eventId] = safe;
      }
      final records = <TelemetryEventRecord>[];
      for (final record in replayableRecords) {
        final prepared = preparedById[record.eventId];
        if (prepared != null) records.add(prepared);
      }
      if (records.isEmpty) return 0;
      final pendingRecords = records
          .where((record) => record.syncState == TelemetrySyncState.pending)
          .toList();

      try {
        await _ensureAuthenticated();
      } catch (e) {
        _lastSyncError = _describeError(e);
        if (pendingRecords.isNotEmpty) {
          await _handleUploadFailure(pendingRecords, _asUploadException(e));
        }
        return 0;
      }
      if (!_hasValidToken) {
        if (pendingRecords.isNotEmpty) {
          await _handleAuthenticationFailure(pendingRecords);
        } else {
          _lastSyncError = 'Device authentication failed';
        }
        return 0;
      }

      var totalReplayed = 0;
      final batchSize = activePolicy.maxBatchSize > 0
          ? activePolicy.maxBatchSize
          : 50;
      for (var i = 0; i < records.length; i += batchSize) {
        final end = min(i + batchSize, records.length);
        final batch = records.sublist(i, end);
        final result = await _uploadReplayBatch(batch);
        if (result == null ||
            !await _applyReplayUploadResult(result, records: batch)) {
          return 0;
        }
        totalReplayed += batch.length;
      }

      // Replay is a state-preserving developer operation for rows that were
      // already synced. Capacity maintenance runs on the durable recording
      // cadence; purging here could physically delete a replayed synced row.
      _cancelRetryTimer();
      _lastSyncTime = _now();
      _lastSyncError = null;
      return totalReplayed;
    } catch (e) {
      _lastSyncError = _describeError(e);
      if (e is TelemetryUploadException && e.isUnauthorized) {
        _clearAuthToken();
      }
      return 0;
    }
  }

  Future<TelemetryBatchUploadResult?> _uploadReplayBatch(
    List<TelemetryEventRecord> batch,
  ) async {
    final pending = batch
        .where((record) => record.syncState == TelemetrySyncState.pending)
        .toList();

    Future<void> handleFailure(TelemetryUploadException error) async {
      if (pending.isEmpty) {
        _lastSyncError = _describeError(error);
      } else if (error.isPermanentClientError) {
        await _rejectPermanentBatch(pending, error);
      } else {
        await _handleUploadFailure(pending, error);
      }
    }

    try {
      return await transport.uploadBatch(
        baseUrl: config.baseUrl,
        authToken: _authToken!,
        deviceId: config.deviceId,
        records: batch,
      );
    } on TelemetryUploadException catch (error) {
      if (!error.isUnauthorized) {
        await handleFailure(error);
        return null;
      }

      // Replay follows the same single re-authentication boundary as normal
      // upload, while keeping originally synced rows out of retry bookkeeping.
      _clearAuthToken();
      try {
        await _ensureAuthenticated();
        if (!_hasValidToken) {
          await handleFailure(
            const TelemetryUploadException('Device authentication failed'),
          );
          return null;
        }
        return await transport.uploadBatch(
          baseUrl: config.baseUrl,
          authToken: _authToken!,
          deviceId: config.deviceId,
          records: batch,
        );
      } on Object catch (retryError) {
        if (retryError is TelemetryUploadException &&
            retryError.isUnauthorized) {
          _clearAuthToken();
        }
        await handleFailure(_asUploadException(retryError));
        return null;
      }
    } on Object catch (error) {
      await handleFailure(_asUploadException(error));
      return null;
    }
  }

  Future<bool> _applyReplayUploadResult(
    TelemetryBatchUploadResult result, {
    required List<TelemetryEventRecord> records,
  }) async {
    final expectedIds = records.map((record) => record.eventId).toSet();
    final acknowledgedIds = <String>{};
    final validAcks = <TelemetryAckResult>[];
    var invalidResponse = expectedIds.length != records.length;
    for (final ack in result.ackResults) {
      if (!_isKnownTelemetryAckStatus(ack.status) ||
          !expectedIds.contains(ack.eventId) ||
          !acknowledgedIds.add(ack.eventId)) {
        invalidResponse = true;
        continue;
      }
      validAcks.add(ack);
    }

    const invalidAckError = TelemetryUploadException(
      'Telemetry upload response is invalid',
      statusCode: 502,
      errorCode: 'INVALID_RESPONSE',
    );
    final pending = records
        .where((record) => record.syncState == TelemetrySyncState.pending)
        .toList();
    if (invalidResponse) {
      // An ambiguous response only advances normal pending rows. Originally
      // synced rows are deliberately excluded from retry bookkeeping.
      if (pending.isNotEmpty) {
        await _handleUploadFailure(pending, invalidAckError);
      } else {
        _lastSyncError = _describeError(invalidAckError);
      }
      return false;
    }

    final pendingIds = pending.map((record) => record.eventId).toSet();
    final pendingAcks = validAcks
        .where((ack) => pendingIds.contains(ack.eventId))
        .toList();
    final unacknowledgedPending = pending
        .where((record) => !acknowledgedIds.contains(record.eventId))
        .toList();
    try {
      if (pendingAcks.isNotEmpty) {
        await storage.applyAckResults(pendingAcks);
      }
      if (unacknowledgedPending.isNotEmpty) {
        await _handleUploadFailure(unacknowledgedPending, invalidAckError);
        return false;
      }
      return true;
    } on Object {
      // Without a durable local ACK, pending rows remain replayable. Synced
      // rows are never touched by this failure path.
      _recordStorageFailure();
      return false;
    }
  }

  TelemetryUploadException _asUploadException(Object error) {
    if (error is TelemetryUploadException) return error;
    return TelemetryUploadException(_describeError(error));
  }

  Future<void> _rejectPermanentBatch(
    List<TelemetryEventRecord> records,
    TelemetryUploadException error,
  ) async {
    final results = [
      for (final record in records)
        TelemetryAckResult(
          eventId: record.eventId,
          status: 'rejected',
          reason:
              _safeTelemetryErrorCode(error.errorCode) ??
              'Telemetry upload rejected',
        ),
    ];
    try {
      await storage.applyAckResults(results);
    } on Object {
      _recordStorageFailure();
      return;
    }
    _lastSyncError = _describeError(error);
  }
}
