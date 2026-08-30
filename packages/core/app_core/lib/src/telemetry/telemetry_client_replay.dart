part of 'telemetry_client.dart';

/// Developer-controlled replay operations.
///
/// Keeping this state machine separate from the automatic uploader makes the
/// distinction between broad historical replay and explicit rejected retry
/// visible at the library boundary.
mixin _TelemetryClientReplay on _TelemetryClientBase {
  /// Explicitly retries only rows previously marked `rejected`.
  ///
  /// Unlike automatic upload, transient failures here leave the row rejected:
  /// a developer action must never put a permanently rejected record back into
  /// the automatic pending queue.
  Future<int> retryRejectedRecords() {
    if (_isDisposed || _isUploading) return Future<int>.value(0);
    _cancelRetryTimer();
    _isUploading = true;
    final operation = _retryRejectedRecords();
    final trackedOperation = operation.then<void>((_) {});
    _uploadFuture = trackedOperation;
    return operation.whenComplete(() => _completeUpload(trackedOperation));
  }

  Future<int> _retryRejectedRecords() async {
    try {
      await ready;
      if (_isDisposed || !activePolicy.uploadEnabled) return 0;
      final persisted = await storage.fetchRejectedForReplay();
      if (persisted.isEmpty) return 0;
      final records = await _preparePersistedRecords(persisted);
      if (records.isEmpty) return 0;

      try {
        await _ensureAuthenticated();
      } catch (e) {
        _lastSyncError = _describeError(e);
        // Keep rejected rows untouched and do not schedule automatic retry.
        return 0;
      }
      if (!_hasValidToken) {
        _lastSyncError = 'Device authentication failed';
        return 0;
      }

      var retriedCount = 0;
      final batchSize = activePolicy.maxBatchSize > 0
          ? activePolicy.maxBatchSize
          : 50;
      for (var i = 0; i < records.length; i += batchSize) {
        final end = min(i + batchSize, records.length);
        final batch = records.sublist(i, end);
        TelemetryBatchUploadResult result;
        try {
          result = await transport.uploadBatch(
            baseUrl: config.baseUrl,
            authToken: _authToken!,
            deviceId: config.deviceId,
            records: batch,
          );
        } on TelemetryUploadException catch (error) {
          if (error.isUnauthorized) {
            _clearAuthToken();
            try {
              await _ensureAuthenticated();
              if (!_hasValidToken) {
                _lastSyncError = 'Device authentication failed';
                return 0;
              }
              result = await transport.uploadBatch(
                baseUrl: config.baseUrl,
                authToken: _authToken!,
                deviceId: config.deviceId,
                records: batch,
              );
            } catch (retryError) {
              if (retryError is TelemetryUploadException &&
                  retryError.isUnauthorized) {
                _clearAuthToken();
              }
              _lastSyncError = _describeError(retryError);
              return 0;
            }
          } else {
            _lastSyncError = _describeError(error);
            return 0;
          }
        } on Object catch (error) {
          _lastSyncError = _describeError(error);
          return 0;
        }

        if (!await _applyRejectedRetryResult(result, records: batch)) {
          return 0;
        }
        retriedCount += batch.length;
      }

      var purgeFailed = false;
      try {
        await storage.purgeOldSyncedRecords(
          targetCapacity: activePolicy.clientMaxLocalRecords,
        );
      } on Object {
        // Accepted rows are already durable; capacity maintenance is best
        // effort and must not turn a successful manual retry into a failure.
        _recordStorageFailure();
        purgeFailed = true;
      }
      _cancelRetryTimer();
      _lastSyncTime = _now();
      if (!purgeFailed) _lastSyncError = null;
      return retriedCount;
    } on Object catch (error) {
      _lastSyncError = _describeError(error);
      return 0;
    }
  }

  Future<bool> _applyRejectedRetryResult(
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
    if (invalidResponse || acknowledgedIds.length != records.length) {
      _lastSyncError = 'Telemetry request failed (INVALID_RESPONSE)';
      return false;
    }
    try {
      await storage.applyAckResults(validAcks);
      return true;
    } on Object {
      _recordStorageFailure();
      return false;
    }
  }
}
