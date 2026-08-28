part of 'telemetry_client.dart';

mixin _TelemetryClientLifecycle on _TelemetryClientBase {
  void _startTimers() {
    _resetPeriodicFlushTimer();
    _policyRefreshTimer?.cancel();
    _policyRefreshTimer = null;
    if (config.policyFetchIntervalSeconds > 0) {
      _policyRefreshTimer = _timerFactory.schedulePeriodic(
        Duration(seconds: config.policyFetchIntervalSeconds),
        () async {
          await refreshPolicy();
        },
      );
    }
  }

  void _resetPeriodicFlushTimer() {
    _periodicFlushTimer?.cancel();
    _periodicFlushTimer = null;
    if (!activePolicy.uploadEnabled || activePolicy.timeIntervalSeconds <= 0) {
      return;
    }
    _periodicFlushTimer = _timerFactory.schedulePeriodic(
      Duration(seconds: activePolicy.timeIntervalSeconds),
      () => _requestUpload(),
    );
  }

  /// Refreshes the remote upload policy with a single-flight guard.
  Future<bool> refreshPolicy() {
    if (_isDisposed) return Future<bool>.value(false);
    final inFlight = _policyRefreshFuture;
    if (inFlight != null) {
      _policyRefreshRequested = true;
      return inFlight;
    }

    final operation = _refreshPolicyOnce();
    late final Future<bool> tracked;
    tracked = operation.then((success) {
      _completePolicyRefresh(tracked);
      return success;
    });
    _policyRefreshFuture = tracked;
    return tracked;
  }

  void _completePolicyRefresh(Future<bool> operation) {
    if (!identical(_policyRefreshFuture, operation)) return;
    _policyRefreshFuture = null;
    final refreshAgain = _policyRefreshRequested;
    _policyRefreshRequested = false;
    if (refreshAgain && !_isDisposed) unawaited(refreshPolicy());
  }

  Future<bool> _refreshPolicyOnce() async {
    String? requestedToken;
    var requestedTokenGeneration = _authTokenGeneration;
    try {
      await _ensureAuthenticated();
      if (!_hasValidToken) return false;

      requestedToken = _authToken;
      requestedTokenGeneration = _authTokenGeneration;
      final policy = await transport.fetchRemotePolicy(
        baseUrl: config.baseUrl,
        authToken: requestedToken!,
      );
      if (policy != null) {
        activePolicy = policy;
        _lastPolicyFetchTime = _now();
        if (!_isDisposed) _resetPeriodicFlushTimer();
        return true;
      }
    } catch (e) {
      _lastSyncError = _describeError(e);
      if (e is TelemetryUploadException &&
          e.isUnauthorized &&
          requestedToken != null &&
          requestedTokenGeneration == _authTokenGeneration &&
          requestedToken == _authToken) {
        _clearAuthToken();
      }
    }
    return false;
  }

  /// Triggered on App backgrounding.
  void onAppBackground() {
    if (_isDisposed) return;
    if (activePolicy.triggerAppBackground) unawaited(_requestUpload());
  }

  /// Triggered on App foregrounding with backlog.
  void onAppForeground() {
    if (_isDisposed) return;
    if (activePolicy.triggerAppForegroundWithBacklog) {
      unawaited(_requestUpload());
    }
  }

  /// Triggered on network recovery.
  void onNetworkRecovered() {
    if (_isDisposed) return;
    if (activePolicy.triggerNetworkRecovered) unawaited(_requestUpload());
  }

  /// Returns the latest cached diagnostics and storage health snapshot.
  TelemetryDiagnosticsSnapshot get latestDiagnostics {
    final health =
        storage.cachedHealthStats ??
        const TelemetryStorageHealth(
          localPendingCount: 0,
          localRejectedCount: 0,
          localSyncedCount: 0,
          totalCount: 0,
          cacheOverflow: false,
        );
    return _diagnosticsFromHealth(health);
  }

  /// Retrieves fresh diagnostics and storage health.
  Future<TelemetryDiagnosticsSnapshot> getDiagnostics() async {
    final health = await storage.getHealthStats(
      targetCapacity: activePolicy.clientMaxLocalRecords,
    );
    return _diagnosticsFromHealth(health);
  }

  TelemetryDiagnosticsSnapshot _diagnosticsFromHealth(
    TelemetryStorageHealth health,
  ) {
    return TelemetryDiagnosticsSnapshot(
      localPendingCount: health.localPendingCount,
      localRejectedCount: health.localRejectedCount,
      localSyncedCount: health.localSyncedCount,
      totalCount: health.totalCount,
      cacheOverflow: health.cacheOverflow,
      uploadEnabled: activePolicy.uploadEnabled,
      policyVersion: activePolicy.policyVersion,
      batchSizeThreshold: activePolicy.batchSizeThreshold,
      timeIntervalSeconds: activePolicy.timeIntervalSeconds,
      maxBatchSize: activePolicy.maxBatchSize,
      clientMaxLocalRecords: activePolicy.clientMaxLocalRecords,
      lastSyncTime: _lastSyncTime,
      lastSyncError: _lastSyncError,
      lastPolicyFetchTime: _lastPolicyFetchTime,
      isUploading: _isUploading,
    );
  }

  /// Stops new work, drains in-flight operations, then closes storage once.
  Future<void> dispose() {
    final inFlight = _disposeFuture;
    if (inFlight != null) return inFlight;

    _isDisposed = true;
    _periodicFlushTimer?.cancel();
    _periodicFlushTimer = null;
    _cancelRetryTimer();
    _policyRefreshTimer?.cancel();
    _policyRefreshTimer = null;

    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    final authentication = _authenticationFuture;
    if (authentication != null) {
      try {
        await authentication;
      } on Object {
        // Diagnostics already capture authentication failures.
      }
    }

    final policyRefresh = _policyRefreshFuture;
    if (policyRefresh != null) {
      try {
        await policyRefresh;
      } on Object {
        // Wait for policy requests so no background request outlives the client.
      }
    }

    final upload = _uploadFuture;
    if (upload != null) {
      try {
        await upload;
      } on Object {
        // Pending rows and diagnostics retain upload failures.
      }
    }

    // Drain writes queued immediately before disposal before closing storage.
    await _recordQueue;
    final uploadAfterRecords = _uploadFuture;
    if (uploadAfterRecords != null) {
      try {
        await uploadAfterRecords;
      } on Object {
        // The upload path records its own diagnostic state.
      }
    }
    await storage.close();
  }
}
