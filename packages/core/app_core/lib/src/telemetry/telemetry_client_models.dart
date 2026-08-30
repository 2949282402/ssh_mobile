part of 'telemetry_client.dart';

/// Upload/network failure used by the dispatcher to classify retry behavior.
///
/// A `null` [statusCode] represents a connection-layer failure. [errorCode]
/// is always treated as an untrusted machine-readable value and is sanitized
/// before it reaches client diagnostics.
class TelemetryUploadException implements Exception {
  const TelemetryUploadException(
    this.message, {
    this.statusCode,
    this.retryAfterSeconds,
    this.errorCode,
  });

  final String message;
  final int? statusCode;
  final int? retryAfterSeconds;
  final String? errorCode;

  bool get isUnauthorized => statusCode == 401;
  bool get isAlreadyEnrolled =>
      statusCode == 409 &&
      (errorCode == 'ALREADY_ENROLLED' || message == 'ALREADY_ENROLLED');
  bool get isRateLimited => statusCode == 429;
  bool get isPermanentClientError =>
      statusCode != null &&
      statusCode! >= 400 &&
      statusCode! < 500 &&
      statusCode != 401 &&
      statusCode != 429;
  bool get isServerError =>
      statusCode == null || (statusCode! >= 500 && statusCode! < 600);

  @override
  String toString() =>
      'TelemetryUploadException($message, '
      'statusCode: $statusCode, retryAfterSeconds: $retryAfterSeconds, '
      'errorCode: $errorCode)';
}

/// Configuration for [TelemetryClient].
class TelemetryClientConfig {
  const TelemetryClientConfig({
    required this.baseUrl,
    required this.deviceId,
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    required this.releaseChannel,
    this.sessionId,
    this.deviceEnrollmentSecret,
    this.deviceEnrollmentProvider,
    this.authTokenTtlSeconds = 2 * 60 * 60,
    this.policyFetchIntervalSeconds = 3600,
  });

  final String baseUrl;
  final String deviceId;
  final String appVersion;
  final String buildNumber;
  final String platform;
  final String releaseChannel;

  /// App-lifetime session ID. A UUID v4 is generated when omitted.
  final String? sessionId;

  /// Device enrollment secret used for HMAC-SHA256 authentication proof.
  final String? deviceEnrollmentSecret;

  /// App-owned provider for bootstrapping the telemetry secret from Relay.
  final TelemetryDeviceEnrollmentProvider? deviceEnrollmentProvider;

  /// Legacy compatibility value. Server-provided `expiresIn` is authoritative.
  final int authTokenTtlSeconds;

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
    this.oldestPendingAge,
    this.oldestRejectedAge,
    this.overflowCount = 0,
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
  final Duration? oldestPendingAge;
  final Duration? oldestRejectedAge;
  final int overflowCount;
  final DateTime? lastSyncTime;
  final String? lastSyncError;
  final DateTime? lastPolicyFetchTime;
  final bool isUploading;
}

/// Result of a batch upload, including one ACK per server-visible record.
class TelemetryBatchUploadResult {
  const TelemetryBatchUploadResult({required this.ackResults});

  final List<TelemetryAckResult> ackResults;
}
