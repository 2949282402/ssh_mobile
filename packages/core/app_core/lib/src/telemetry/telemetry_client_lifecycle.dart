part of 'telemetry_client.dart';

mixin _TelemetryClientLifecycle on _TelemetryClientBase {
  /// Loads the durable policy before timers or upload work can observe it.
  ///
  /// Storage failures keep the configured policy in force. A failed restore is
  /// intentionally non-fatal to telemetry recording, but is visible through
  /// the existing diagnostics channel.
  void _beginPolicyRestore() {
    final operation = _restoreLastKnownGoodPolicy();
    _policyReadyFuture = operation;
  }

  Future<void> _restoreLastKnownGoodPolicy() async {
    try {
      final persisted = await storage.loadLastKnownGoodPolicy();
      if (persisted != null && _isValidPolicy(persisted)) {
        // Equal versions are safe to restore; lower versions can never
        // replace a policy already selected by configuration.
        if (persisted.policyVersion >= activePolicy.policyVersion) {
          activePolicy = persisted;
        }
      }
    } on Object {
      _recordStorageFailure();
    }
    if (!_isDisposed) _startTimers();
  }

  /// Restored and remote policies must stay within the client safety envelope.
  /// The server parser may clamp untrusted JSON, but typed policy instances
  /// still need this boundary before they reach timers or storage.
  bool _isValidPolicy(TelemetryUploadPolicy policy) {
    const supportedTriggers = {
      'highPriorityError',
      'appBackground',
      'networkRecovered',
      'appForegroundWithBacklog',
    };
    return policy.policyVersion > 0 &&
        policy.policyVersion <= 0x7fffffff &&
        policy.batchSizeThreshold >=
            TelemetryUploadPolicy.minBatchSizeThreshold &&
        policy.batchSizeThreshold <=
            TelemetryUploadPolicy.maxBatchSizeThreshold &&
        policy.timeIntervalSeconds >=
            TelemetryUploadPolicy.minTimeIntervalSeconds &&
        policy.timeIntervalSeconds <=
            TelemetryUploadPolicy.maxTimeIntervalSeconds &&
        policy.maxBatchSize >= TelemetryUploadPolicy.minMaxBatchSize &&
        policy.maxBatchSize <= TelemetryUploadPolicy.maxMaxBatchSize &&
        policy.clientMaxLocalRecords >=
            TelemetryUploadPolicy.minClientMaxLocalRecords &&
        policy.clientMaxLocalRecords <=
            TelemetryUploadPolicy.maxClientMaxLocalRecords &&
        policy.specialTriggers.length ==
            policy.specialTriggers.toSet().length &&
        policy.specialTriggers.every(supportedTriggers.contains);
  }

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
      await ready;
      if (_isDisposed) return false;
      await _ensureAuthenticated();
      if (!_hasValidToken) return false;

      requestedToken = _authToken;
      requestedTokenGeneration = _authTokenGeneration;
      final policy = await transport.fetchRemotePolicy(
        baseUrl: config.baseUrl,
        authToken: requestedToken!,
      );
      if (policy != null) {
        if (!_isValidPolicy(policy) ||
            policy.policyVersion < activePolicy.policyVersion) {
          return false;
        }
        try {
          await storage.saveLastKnownGoodPolicy(policy);
        } on Object {
          _recordStorageFailure();
          return false;
        }
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
          overflowCount: 0,
        );
    return _diagnosticsFromHealth(health);
  }

  /// Retrieves fresh diagnostics and storage health.
  Future<TelemetryDiagnosticsSnapshot> getDiagnostics() async {
    await ready;
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
      oldestPendingAge: health.oldestPendingAge,
      oldestRejectedAge: health.oldestRejectedAge,
      overflowCount: health.overflowCount,
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
    final policyReady = _policyReadyFuture;
    if (policyReady != null) {
      try {
        await policyReady;
      } on Object {
        // Restore failures retain the configured policy and diagnostics.
      }
    }

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
