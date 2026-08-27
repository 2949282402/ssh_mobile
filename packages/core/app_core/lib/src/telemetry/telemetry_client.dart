import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'telemetry_catalog.dart';
import 'telemetry_endpoints.dart';
import 'telemetry_model.dart';
import 'telemetry_policy.dart';
import 'telemetry_storage.dart';

/// 上传过程中的 HTTP / 连接错误，供上传分发器按状态码决策。
///
/// [statusCode] 为 `null` 时表示纯连接层错误（不支持状态码的重试场景）。
class TelemetryUploadException implements Exception {
  const TelemetryUploadException(
    this.message, {
    this.statusCode,
    this.retryAfterSeconds,
  });

  final String message;
  final int? statusCode;
  final int? retryAfterSeconds;

  bool get isUnauthorized => statusCode == 401;
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
  String toString() => 'TelemetryUploadException($message, '
      'statusCode: $statusCode, retryAfterSeconds: $retryAfterSeconds)';
}

/// Configuration for TelemetryClient.
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
    this.authTokenTtlSeconds = 2 * 60 * 60,
    this.policyFetchIntervalSeconds = 3600,
  });

  final String baseUrl;
  final String deviceId;
  final String appVersion;
  final String buildNumber;
  final String platform;
  final String releaseChannel;

  /// App 运行期固定的会话 ID；缺省时在客户端创建时生成 UUID v4。
  final String? sessionId;

  /// 设备注册密钥，用于 HMAC-SHA256 认证证明。生产由安全存储读取。
  final String? deviceEnrollmentSecret;

  /// 认证令牌缓存 TTL（秒），默认 2 小时。
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

/// 批量上传的网络结果，包含服务端返回的单条 ACK 与可能的 429 重试时间。
class TelemetryBatchUploadResult {
  const TelemetryBatchUploadResult({required this.ackResults});

  final List<TelemetryAckResult> ackResults;
}

/// Abstract transport contract for Telemetry network operations.
abstract class TelemetryTransport {
  Future<String?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  });

  Future<TelemetryUploadPolicy?> fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
  });

  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  });
}

/// 认证证明的计算入口，便于测试注入固定签名。
abstract class TelemetryProofFactory {
  const TelemetryProofFactory();

  /// 生成 `telemetry:auth:$deviceId:$expEpoch` 的 HMAC-SHA256 十六进制签名。
  String sign({
    required String enrollmentSecret,
    required String deviceId,
    required int expEpoch,
  });
}

/// 默认 HMAC-SHA256 证明实现。
class HmacTelemetryProofFactory extends TelemetryProofFactory {
  const HmacTelemetryProofFactory();

  @override
  String sign({
    required String enrollmentSecret,
    required String deviceId,
    required int expEpoch,
  }) {
    final payload = 'telemetry:auth:$deviceId:$expEpoch';
    final derivedKey = sha256.convert(utf8.encode(enrollmentSecret)).toString();
    final hmac = Hmac(sha256, utf8.encode(derivedKey));
    final digest = hmac.convert(utf8.encode(payload));
    return digest.toString();
  }
}

/// Default standard HTTP transport implementation using standard dart:io.
class HttpTelemetryTransport implements TelemetryTransport {
  HttpTelemetryTransport({
    HttpClient? client,
    TelemetryProofFactory? proofFactory,
  }) : _client = client ?? HttpClient(),
       _proofFactory = proofFactory ?? const HmacTelemetryProofFactory();

  final HttpClient _client;
  final TelemetryProofFactory _proofFactory;

  @override
  Future<String?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async {
    final uri = TelemetryEndpoints.resolveUri(
      baseUrl,
      TelemetryEndpoints.publicAuthPath,
    );

    // 设备注册成功后，通过 HMAC 证明换取短期 bearer token。
    String? secret;
    int? proofEpoch;
    if (authSecret != null && authSecret.isNotEmpty) {
      secret = authSecret;
      proofEpoch =
          expEpoch ??
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 60;
    }

    final payload = <String, dynamic>{
      'deviceId': deviceId,
      'platform': platform,
      'appVersion': appVersion,
      'expEpoch': ?proofEpoch,
      if (secret != null && proofEpoch != null)
        'proof': _proofFactory.sign(
          enrollmentSecret: secret,
          deviceId: deviceId,
          expEpoch: proofEpoch,
        ),
    };

    final req = await _client.postUrl(uri);
    req.headers.set('Content-Type', 'application/json');
    req.add(utf8.encode(jsonEncode(payload)));
    final res = await req.close();
    final resBody = await utf8.decodeStream(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final data = jsonDecode(resBody) as Map<String, dynamic>;
      return data['token'] as String?;
    }
    if (res.statusCode == 401) {
      throw const TelemetryUploadException(
        'Telemetry device authentication rejected',
        statusCode: 401,
      );
    }
    throw TelemetryUploadException(
      'Telemetry device authentication failed with status '
      '${res.statusCode}: $resBody',
      statusCode: res.statusCode,
    );
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
    throw TelemetryUploadException(
      'Telemetry policy fetch failed with status ${res.statusCode}: $resBody',
      statusCode: res.statusCode,
    );
  }

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
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
      return TelemetryBatchUploadResult(
        ackResults: resultsJson
            .map(
              (item) =>
                  TelemetryAckResult.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
      );
    }

    int? retryAfter;
    if (res.statusCode == 429) {
      final header = res.headers.value('retry-after');
      if (header != null) {
        final seconds = int.tryParse(header);
        retryAfter = seconds;
      }
    }

    throw TelemetryUploadException(
      'Telemetry upload failed with status ${res.statusCode}: $resBody',
      statusCode: res.statusCode,
      retryAfterSeconds: retryAfter,
    );
  }
}

/// 客户端事件构建与上传分发器。
///
/// 状态机：
/// - `sessionId` 在客户端创建时由 UUID v4 生成，App 运行期固定。
/// - `traceId` 未显式传入时每调用生成一次 UUID v4。
/// - 服务端 ACK 成功后记录推进到 `synced + logicalDeletedAt=now`，随后执行
///   FIFO 淘汰；网络失败记录保持在 `pending` 状态并累计 `retryCount`。
class TelemetryClient {
  TelemetryClient({
    required this.config,
    required this.storage,
    TelemetryCatalog? catalog,
    TelemetryTransport? transport,
    TelemetryUploadPolicy? initialPolicy,
  }) : catalog = catalog ?? TelemetryCatalog.instance,
       transport = transport ?? HttpTelemetryTransport(),
       activePolicy = initialPolicy ?? TelemetryUploadPolicy.defaultPolicy(),
       sessionId = config.sessionId ?? _uuid.v4() {
    _startTimers();
  }

  static const Uuid _uuid = Uuid();

  final TelemetryClientConfig config;
  final TelemetryStorage storage;
  final TelemetryCatalog catalog;
  final TelemetryTransport transport;

  /// App 运行期固定的会话 ID。
  final String sessionId;

  TelemetryUploadPolicy activePolicy;
  String? _authToken;
  DateTime? _authTokenExpiresAt;
  DateTime? _lastSyncTime;
  String? _lastSyncError;
  DateTime? _lastPolicyFetchTime;

  bool _isUploading = false;
  bool _isDisposed = false;
  Timer? _flushTimer;
  Timer? _policyTimer;

  static String _newTraceId() => _uuid.v4();

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

  /// 是否有未过期的缓存认证令牌。
  bool get _hasValidToken =>
      _authToken != null &&
      _authToken!.isNotEmpty &&
      _authTokenExpiresAt != null &&
      _authTokenExpiresAt!.isAfter(DateTime.now().toUtc());

  /// 记录一个 Analytics/系统事件（经 Catalog 校验后写入存储）。
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
    final eventId = 'evt_${_uuid.v4()}';

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
      sessionId: sessionId ?? this.sessionId,
      traceId: traceId ?? _newTraceId(),
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

    // 触发条件：高优先级错误或批量条数阈值。
    final isHighPriorityError =
        severity == TelemetrySeverity.error ||
        severity == TelemetrySeverity.critical;
    if (isHighPriorityError && activePolicy.triggerHighPriorityError) {
      unawaited(flush());
    } else {
      final pending = await storage.fetchPendingBatch(
        activePolicy.batchSizeThreshold,
      );
      if (pending.length >= activePolicy.batchSizeThreshold) {
        unawaited(flush());
      }
    }

    return true;
  }

  /// 记录一条诊断日志记录。
  Future<bool> recordDiagnostic({
    required String message,
    required TelemetrySeverity severity,
    String? eventName,
    String? feature,
    String? category,
    String? stackTrace,
    String? errorCode,
    Map<String, dynamic>? properties,
    String? sessionId,
    String? traceId,
  }) async {
    if (_isDisposed) return false;

    final now = DateTime.now().toUtc();
    final eventId = 'diag_${_uuid.v4()}';

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

    final resolvedEventName = eventName ?? 'app.diagnostic.log';
    final resolvedFeature = feature ?? 'app';
    final record = TelemetryEventRecord(
      eventId: eventId,
      recordType: TelemetryRecordType.diagnostic,
      eventName: resolvedEventName,
      eventVersion: 1,
      deviceId: config.deviceId,
      sessionId: sessionId ?? this.sessionId,
      traceId: traceId ?? _newTraceId(),
      occurredAt: now,
      feature: resolvedFeature,
      severity: severity,
      appVersion: config.appVersion,
      buildNumber: config.buildNumber,
      platform: config.platform,
      properties: {
        'message': message,
        'category': ?category,
        ...?properties,
      },
      error: errorDetail,
    );

    if (!catalog.isValidRecord(record)) {
      return false;
    }

    await storage.insertRecord(record);

    // 诊断日志同样遵循高优先级错误与批量阈值触发。
    final isHighPriorityError =
        severity == TelemetrySeverity.error ||
        severity == TelemetrySeverity.critical;
    if (isHighPriorityError && activePolicy.triggerHighPriorityError) {
      unawaited(flush());
    } else {
      final pending = await storage.fetchPendingBatch(
        activePolicy.batchSizeThreshold,
      );
      if (pending.length >= activePolicy.batchSizeThreshold) {
        unawaited(flush());
      }
    }

    return true;
  }

  /// 刷新远程上传策略并应用安全边界。
  Future<bool> refreshPolicy() async {
    if (_isDisposed) return false;
    try {
      await _ensureAuthenticated();
      if (_authToken == null || _authToken!.isEmpty) {
        return false;
      }

      final policy = await transport.fetchRemotePolicy(
        baseUrl: config.baseUrl,
        authToken: _authToken!,
      );

      if (policy != null) {
        activePolicy = policy;
        _lastPolicyFetchTime = DateTime.now().toUtc();
        _resetFlushTimer();
        return true;
      }
    } catch (e) {
      _lastSyncError = e.toString();
      if (e is TelemetryUploadException && e.isUnauthorized) {
        _authToken = null;
        _authTokenExpiresAt = null;
      }
    }
    return false;
  }

  /// 确保存在未过期的认证令牌；使用设备注册密钥做 HMAC 证明（缺失密钥时 Fail-Closed）。
  Future<void> _ensureAuthenticated() async {
    if (_hasValidToken) return;

    final secret = config.deviceEnrollmentSecret;
    if (secret == null || secret.isEmpty) {
      _lastSyncError = 'Missing deviceEnrollmentSecret';
      return;
    }

    final expEpoch =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 60;
    final token = await transport.authenticateDevice(
      baseUrl: config.baseUrl,
      deviceId: config.deviceId,
      platform: config.platform,
      appVersion: config.appVersion,
      authSecret: secret,
      expEpoch: expEpoch,
    );
    if (token != null && token.isNotEmpty) {
      _authToken = token;
      _authTokenExpiresAt = DateTime.now().toUtc().add(
        Duration(seconds: config.authTokenTtlSeconds),
      );
    }
  }

  /// 刷新待上传记录，内置单飞守卫、401 重认证、5xx/4xx 决策与重试退避。
  Future<void> flush() async {
    if (_isDisposed || _isUploading || !activePolicy.uploadEnabled) return;
    _isUploading = true;

    try {
      await _flushWithToken();
    } finally {
      _isUploading = false;
    }
  }

  Future<void> _flushWithToken() async {
    final batchSize = activePolicy.maxBatchSize > 0
        ? activePolicy.maxBatchSize
        : 50;
    final pending = await storage.fetchPendingBatch(batchSize);
    if (pending.isEmpty) {
      return;
    }

    // 单飞：认证失败时保持记录 pending，绝不删除。
    try {
      await _ensureAuthenticated();
    } catch (e) {
      _lastSyncError = _describeError(e);
      return;
    }
    if (_authToken == null || _authToken!.isEmpty) {
      _lastSyncError = 'Device authentication failed';
      return;
    }

    try {
      final result = await transport.uploadBatch(
        baseUrl: config.baseUrl,
        authToken: _authToken!,
        deviceId: config.deviceId,
        records: pending,
      );

      await storage.applyAckResults(result.ackResults);
      await storage.purgeOldSyncedRecords(
        targetCapacity: activePolicy.clientMaxLocalRecords,
      );

      _lastSyncTime = DateTime.now().toUtc();
      _lastSyncError = null;
      return;
    } on TelemetryUploadException catch (e) {
      if (e.isUnauthorized) {
        // 清除失效令牌，只重认证一次后重试本批。
        _authToken = null;
        _authTokenExpiresAt = null;
        try {
          await _ensureAuthenticated();
        } catch (authError) {
          _lastSyncError = _describeError(authError);
          return; // 认证失败：记录保持 pending，绝不删除。
        }
        if (_authToken == null || _authToken!.isEmpty) {
          _lastSyncError = 'Device authentication failed';
          return;
        }
        try {
          final retried = await transport.uploadBatch(
            baseUrl: config.baseUrl,
            authToken: _authToken!,
            deviceId: config.deviceId,
            records: pending,
          );
          await storage.applyAckResults(retried.ackResults);
          await storage.purgeOldSyncedRecords(
            targetCapacity: activePolicy.clientMaxLocalRecords,
          );
          _lastSyncTime = DateTime.now().toUtc();
          _lastSyncError = null;
          return;
        } on TelemetryUploadException catch (retryError) {
          _handleUploadFailure(pending, retryError);
          return;
        }
      } else if (e.isPermanentClientError) {
        // 永久 4xx（如 400 无效 schema）：标记 rejected，停止自动重试。
        final results = [
          for (final r in pending)
            TelemetryAckResult(
              eventId: r.eventId,
              status: 'rejected',
              reason: e.message,
            ),
        ];
        await storage.applyAckResults(results);
        _lastSyncError = e.toString();
        return;
      } else {
        // 5xx / 503 / 连接错误：累计 retryCount，指数退避 + 抖动。
        _handleUploadFailure(pending, e);
        return;
      }
    } catch (e) {
      // 连接层及其他异常按服务器错误处理。
      _handleUploadFailure(
        pending,
        TelemetryUploadException(_describeError(e)),
      );
    }
  }

  void _handleUploadFailure(
    List<TelemetryEventRecord> records,
    TelemetryUploadException error,
  ) {
    _lastSyncError = error.toString();
    if (!error.isPermanentClientError) {
      // 递增 retryCount 并持久化，供后续退避决策使用。
      unawaited(
        storage.applyRetryCount(
          records.map((r) => r.eventId).toList(),
          increment: 1,
        ),
      );
    }
    _scheduleBackoffRetry(records, error);
  }

  /// 429 优先使用 Retry-After；其他场景使用基于 retryCount 的指数退避 + 抖动。
  void _scheduleBackoffRetry(
    List<TelemetryEventRecord> records,
    TelemetryUploadException error,
  ) {
    int delayMs;
    if (error.retryAfterSeconds != null && error.retryAfterSeconds! > 0) {
      delayMs = min(error.retryAfterSeconds! * 1000, 60000);
    } else {
      final maxRetries = records.fold<int>(
        0,
        (acc, r) => max(acc, r.retryCount),
      );
      // 第一次失败时 retryCount 尚未递增，这里 +1 作为本次尝试次数。
      final attempt = max(1, maxRetries + 1);
      final exponential = min(1000 * pow(2, attempt - 1).toInt(), 60000);
      // 抖动 ±20%，避免同批设备同时重试。
      final jitter = Random().nextInt(exponential ~/ 5 + 1) - exponential ~/ 10;
      delayMs = max(1000, exponential + jitter);
    }

    if (_isDisposed) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_isDisposed) return;
      flush();
    });
  }

  static String _describeError(Object error) {
    if (error is TelemetryUploadException) return error.toString();
    if (error is HttpException) return 'Telemetry connection error: ${error.message}';
    return error.toString();
  }

  /// 以原始身份（eventId/sessionId/traceId）重放全部本地记录。
  Future<int> replayAllLocalRecords() async {
    if (_isDisposed || _isUploading) return 0;
    _isUploading = true;

    try {
      final allRecords = await storage.fetchAllForReplay();
      if (allRecords.isEmpty) return 0;

      try {
        await _ensureAuthenticated();
      } catch (e) {
        _lastSyncError = _describeError(e);
        return 0;
      }
      if (_authToken == null || _authToken!.isEmpty) {
        _lastSyncError = 'Device authentication failed';
        return 0;
      }

      var totalReplayed = 0;
      final batchSize = activePolicy.maxBatchSize > 0
          ? activePolicy.maxBatchSize
          : 50;

      for (var i = 0; i < allRecords.length; i += batchSize) {
        final end = min(i + batchSize, allRecords.length);
        final batch = allRecords.sublist(i, end);

        final result = await transport.uploadBatch(
          baseUrl: config.baseUrl,
          authToken: _authToken!,
          deviceId: config.deviceId,
          records: batch,
        );

        await storage.applyAckResults(result.ackResults);
        totalReplayed += batch.length;
      }

      await storage.purgeOldSyncedRecords(
        targetCapacity: activePolicy.clientMaxLocalRecords,
      );
      _lastSyncTime = DateTime.now().toUtc();
      _lastSyncError = null;
      return totalReplayed;
    } catch (e) {
      _lastSyncError = _describeError(e);
      if (e is TelemetryUploadException && e.isUnauthorized) {
        _authToken = null;
        _authTokenExpiresAt = null;
      }
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

  /// Synchronously retrieves latest diagnostics and storage health snapshot.
  TelemetryDiagnosticsSnapshot get latestDiagnostics {
    final health = storage.cachedHealthStats ??
        const TelemetryStorageHealth(
          localPendingCount: 0,
          localRejectedCount: 0,
          localSyncedCount: 0,
          totalCount: 0,
          cacheOverflow: false,
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