import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'telemetry_catalog.dart';
import 'telemetry_endpoints.dart';
import 'telemetry_model.dart';
import 'telemetry_policy.dart';
import 'telemetry_storage.dart';

/// Configuration for TelemetryClient.
class TelemetryClientConfig {
  const TelemetryClientConfig({
    required this.baseUrl,
    required this.deviceId,
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    required this.releaseChannel,
    this.authSecret,
    this.policyFetchIntervalSeconds = 3600,
  });

  final String baseUrl;
  final String deviceId;
  final String appVersion;
  final String buildNumber;
  final String platform;
  final String releaseChannel;
  final String? authSecret;
  final int policyFetchIntervalSeconds;
}

/// Detailed diagnostics snapshot for Developer UI and health inspection.
class TelemetryDiagnosticsSnapshot {
  const TelemetryDiagnosticsSnapshot({
    required this.localPendingCount,
    required this.localRejectedCount,
    required this.localSyncedCount,
    required this.totalCount,
    required this.cacheOverflow,
    required this.uploadEnabled,
    required this.policyVersion,
    required this.batchSizeThreshold,
    required this.timeIntervalSeconds,
    required this.maxBatchSize,
    required this.clientMaxLocalRecords,
    this.lastSyncTime,
    this.lastSyncError,
    this.lastPolicyFetchTime,
    required this.isUploading,
  });

  final int localPendingCount;
  final int localRejectedCount;
  final int localSyncedCount;
  final int totalCount;
  final bool cacheOverflow;
  final bool uploadEnabled;
  final int policyVersion;
  final int batchSizeThreshold;
  final int timeIntervalSeconds;
  final int maxBatchSize;
  final int clientMaxLocalRecords;
  final DateTime? lastSyncTime;
  final String? lastSyncError;
  final DateTime? lastPolicyFetchTime;
  final bool isUploading;
}

/// Abstract transport contract for Telemetry network operations.
abstract class TelemetryTransport {
  Future<String?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
  });

  Future<TelemetryUploadPolicy?> fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
  });

  Future<List<TelemetryAckResult>> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  });
}

/// Default standard HTTP transport implementation using standard dart:io.
class HttpTelemetryTransport implements TelemetryTransport {
  HttpTelemetryTransport({HttpClient? client})
    : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<String?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
  }) async {
    final uri = TelemetryEndpoints.resolveUri(
      baseUrl,
      TelemetryEndpoints.publicAuthPath,
    );
    final req = await _client.postUrl(uri);
    req.headers.set('Content-Type', 'application/json');
    final payload = jsonEncode({
      'deviceId': deviceId,
      'platform': platform,
      'appVersion': appVersion,
      'secret': authSecret,
    });
    req.add(utf8.encode(payload));
    final res = await req.close();
    final resBody = await utf8.decodeStream(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final data = jsonDecode(resBody) as Map<String, dynamic>;
      return data['token'] as String?;
    }
    return null;
  }

  @override
  Future<TelemetryUploadPolicy?> fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
  }) async {
    final uri = TelemetryEndpoints.resolveUri(
      baseUrl,
      TelemetryEndpoints.publicPolicyPath,
    );
    final req = await _client.getUrl(uri);
    if (authToken.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $authToken');
    }
    final res = await req.close();
    final resBody = await utf8.decodeStream(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final data = jsonDecode(resBody) as Map<String, dynamic>;
      return TelemetryUploadPolicy.fromJson(data);
    }
    return null;
  }

  @override
  Future<List<TelemetryAckResult>> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    final uri = TelemetryEndpoints.resolveUri(
      baseUrl,
      TelemetryEndpoints.publicIngestPath,
    );
    final req = await _client.postUrl(uri);
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('X-Device-Id', deviceId);
    if (authToken.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $authToken');
    }
    final payload = jsonEncode({
      'records': records.map((r) => r.toJson()).toList(),
    });
    req.add(utf8.encode(payload));
    final res = await req.close();
    final resBody = await utf8.decodeStream(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final data = jsonDecode(resBody) as Map<String, dynamic>;
      final resultsJson = data['results'] as List<dynamic>? ?? [];
      return resultsJson
          .map(
            (item) => TelemetryAckResult.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    }
    throw HttpException(
      'Telemetry upload failed with status ${res.statusCode}: $resBody',
    );
  }
}

/// Client Runtime & Upload Dispatcher for Telemetry.
class TelemetryClient {
  TelemetryClient({
    required this.config,
    required this.storage,
    TelemetryCatalog? catalog,
    TelemetryTransport? transport,
    TelemetryUploadPolicy? initialPolicy,
  }) : catalog = catalog ?? TelemetryCatalog.instance,
       transport = transport ?? HttpTelemetryTransport(),
       activePolicy = initialPolicy ?? TelemetryUploadPolicy.defaultPolicy() {
    _startTimers();
  }

  final TelemetryClientConfig config;
  final TelemetryStorage storage;
  final TelemetryCatalog catalog;
  final TelemetryTransport transport;

  TelemetryUploadPolicy activePolicy;
  String? _authToken;
  DateTime? _lastSyncTime;
  String? _lastSyncError;
  DateTime? _lastPolicyFetchTime;

  bool _isUploading = false;
  bool _isDisposed = false;
  Timer? _flushTimer;
  Timer? _policyTimer;

  void _startTimers() {
    _resetFlushTimer();
    _policyTimer?.cancel();
    if (config.policyFetchIntervalSeconds > 0) {
      _policyTimer = Timer.periodic(
        Duration(seconds: config.policyFetchIntervalSeconds),
        (_) => refreshPolicy(),
      );
    }
  }

  void _resetFlushTimer() {
    _flushTimer?.cancel();
    if (!activePolicy.uploadEnabled || activePolicy.timeIntervalSeconds <= 0) {
      return;
    }
    _flushTimer = Timer.periodic(
      Duration(seconds: activePolicy.timeIntervalSeconds),
      (_) => flush(),
    );
  }

  /// Records an analytics or system event after Catalog validation.
  Future<bool> recordEvent({
    required String eventName,
    required int eventVersion,
    required String feature,
    required TelemetrySeverity severity,
    required Map<String, dynamic> properties,
    String? sessionId,
    String? traceId,
    String? errorCode,
    String? errorMessage,
  }) async {
    if (_isDisposed) return false;

    final now = DateTime.now().toUtc();
    final eventId =
        'evt_${now.microsecondsSinceEpoch}_${Random().nextInt(100000)}';

    TelemetryErrorDetail? errorDetail;
    if (errorCode != null) {
      errorDetail = TelemetryErrorDetail(
        errorCode: errorCode,
        category: feature,
        terminalFailure: catalog.isTerminalFailure(errorCode),
        message: errorMessage,
      );
    }

    final record = TelemetryEventRecord(
      eventId: eventId,
      recordType: TelemetryRecordType.analytics,
      eventName: eventName,
      eventVersion: eventVersion,
      deviceId: config.deviceId,
      sessionId:
          sessionId ??
          'sess_${config.deviceId.substring(0, min(8, config.deviceId.length))}',
      traceId: traceId ?? 'tr_${now.millisecondsSinceEpoch}',
      occurredAt: now,
      feature: feature,
      severity: severity,
      appVersion: config.appVersion,
      buildNumber: config.buildNumber,
      platform: config.platform,
      properties: properties,
      error: errorDetail,
    );

    if (!catalog.isValidRecord(record)) {
      return false;
    }

    await storage.insertRecord(record);

    // Check triggers
    final isHighPriorityError =
        severity == TelemetrySeverity.error ||
        severity == TelemetrySeverity.critical;
    if (isHighPriorityError && activePolicy.triggerHighPriorityError) {
      unawaited(flush());
    } else {
      // Check batch count trigger
      final pending = await storage.fetchPendingBatch(
        activePolicy.batchSizeThreshold,
      );
      if (pending.length >= activePolicy.batchSizeThreshold) {
        unawaited(flush());
      }
    }

    return true;
  }

  /// Records a diagnostic log record.
  Future<bool> recordDiagnostic({
    required String message,
    required TelemetrySeverity severity,
    String? feature,
    String? category,
    String? stackTrace,
    String? errorCode,
    Map<String, dynamic>? properties,
  }) async {
    if (_isDisposed) return false;

    final now = DateTime.now().toUtc();
    final eventId =
        'diag_${now.microsecondsSinceEpoch}_${Random().nextInt(100000)}';

    TelemetryErrorDetail? errorDetail;
    if (errorCode != null) {
      errorDetail = TelemetryErrorDetail(
        errorCode: errorCode,
        category: category ?? feature ?? 'app',
        terminalFailure: catalog.isTerminalFailure(errorCode),
        message: message,
        stackTrace: stackTrace,
      );
    }

    final record = TelemetryEventRecord(
      eventId: eventId,
      recordType: TelemetryRecordType.diagnostic,
      eventName: 'network.relay.fallback',
      eventVersion: 1,
      deviceId: config.deviceId,
      sessionId:
          'sess_${config.deviceId.substring(0, min(8, config.deviceId.length))}',
      traceId: 'tr_${now.millisecondsSinceEpoch}',
      occurredAt: now,
      feature: feature ?? 'network',
      severity: severity,
      appVersion: config.appVersion,
      buildNumber: config.buildNumber,
      platform: config.platform,
      properties: {'direct_error': message, ...?properties},
      error: errorDetail,
    );

    await storage.insertRecord(record);
    return true;
  }

  /// Refreshes the remote upload policy and applies safety bounds.
  Future<bool> refreshPolicy() async {
    if (_isDisposed) return false;
    try {
      if (_authToken == null || _authToken!.isEmpty) {
        _authToken = await transport.authenticateDevice(
          baseUrl: config.baseUrl,
          deviceId: config.deviceId,
          platform: config.platform,
          appVersion: config.appVersion,
          authSecret: config.authSecret,
        );
      }

      final policy = await transport.fetchRemotePolicy(
        baseUrl: config.baseUrl,
        authToken: _authToken ?? '',
      );

      if (policy != null) {
        activePolicy = policy;
        _lastPolicyFetchTime = DateTime.now().toUtc();
        _resetFlushTimer();
        return true;
      }
    } catch (e) {
      // Retain last known good policy
    }
    return false;
  }

  /// Flushes pending telemetry records to the backend.
  Future<void> flush() async {
    if (_isDisposed || _isUploading || !activePolicy.uploadEnabled) return;
    _isUploading = true;

    try {
      final batchSize = activePolicy.maxBatchSize > 0
          ? activePolicy.maxBatchSize
          : 50;
      final pending = await storage.fetchPendingBatch(batchSize);
      if (pending.isEmpty) {
        return;
      }

      // Ensure authenticated
      if (_authToken == null || _authToken!.isEmpty) {
        _authToken = await transport.authenticateDevice(
          baseUrl: config.baseUrl,
          deviceId: config.deviceId,
          platform: config.platform,
          appVersion: config.appVersion,
          authSecret: config.authSecret,
        );
      }

      if (_authToken == null || _authToken!.isEmpty) {
        _lastSyncError = 'Device authentication failed';
        return;
      }

      final ackResults = await transport.uploadBatch(
        baseUrl: config.baseUrl,
        authToken: _authToken!,
        deviceId: config.deviceId,
        records: pending,
      );

      await storage.applyAckResults(ackResults);
      await storage.purgeOldSyncedRecords(
        targetCapacity: activePolicy.clientMaxLocalRecords,
      );

      _lastSyncTime = DateTime.now().toUtc();
      _lastSyncError = null;
    } catch (e) {
      _lastSyncError = e.toString();
    } finally {
      _isUploading = false;
    }
  }

  /// Replays all local records (synced and rejected included) preserving original identity.
  Future<int> replayAllLocalRecords() async {
    if (_isDisposed || _isUploading) return 0;
    _isUploading = true;

    try {
      final allRecords = await storage.fetchAllForReplay();
      if (allRecords.isEmpty) return 0;

      if (_authToken == null || _authToken!.isEmpty) {
        _authToken = await transport.authenticateDevice(
          baseUrl: config.baseUrl,
          deviceId: config.deviceId,
          platform: config.platform,
          appVersion: config.appVersion,
          authSecret: config.authSecret,
        );
      }

      var totalReplayed = 0;
      final batchSize = activePolicy.maxBatchSize > 0
          ? activePolicy.maxBatchSize
          : 50;

      for (var i = 0; i < allRecords.length; i += batchSize) {
        final end = min(i + batchSize, allRecords.length);
        final batch = allRecords.sublist(i, end);

        final ackResults = await transport.uploadBatch(
          baseUrl: config.baseUrl,
          authToken: _authToken ?? '',
          deviceId: config.deviceId,
          records: batch,
        );

        await storage.applyAckResults(ackResults);
        totalReplayed += batch.length;
      }

      await storage.purgeOldSyncedRecords(
        targetCapacity: activePolicy.clientMaxLocalRecords,
      );
      _lastSyncTime = DateTime.now().toUtc();
      _lastSyncError = null;
      return totalReplayed;
    } catch (e) {
      _lastSyncError = e.toString();
      return 0;
    } finally {
      _isUploading = false;
    }
  }

  /// Triggered on App backgrounding.
  void onAppBackground() {
    if (_isDisposed) return;
    if (activePolicy.triggerAppBackground) {
      unawaited(flush());
    }
  }

  /// Triggered on App foregrounding with backlog.
  void onAppForeground() {
    if (_isDisposed) return;
    if (activePolicy.triggerAppForegroundWithBacklog) {
      unawaited(flush());
    }
  }

  /// Triggered on Network recovered.
  void onNetworkRecovered() {
    if (_isDisposed) return;
    if (activePolicy.triggerNetworkRecovered) {
      unawaited(flush());
    }
  }

  /// Retrieves current diagnostics and storage health.
  Future<TelemetryDiagnosticsSnapshot> getDiagnostics() async {
    final health = await storage.getHealthStats(
      targetCapacity: activePolicy.clientMaxLocalRecords,
    );

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

  /// Closes timers and storage.
  Future<void> dispose() async {
    _isDisposed = true;
    _flushTimer?.cancel();
    _policyTimer?.cancel();
    await storage.close();
  }
}
