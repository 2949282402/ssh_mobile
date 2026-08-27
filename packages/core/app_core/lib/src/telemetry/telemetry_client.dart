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

  /// App 运行期固定的会话 ID；缺省时在客户端创建时生成 UUID v4。
  final String? sessionId;

  /// 设备注册密钥，用于 HMAC-SHA256 认证证明。生产由安全存储读取。
  final String? deviceEnrollmentSecret;

  /// App-owned provider for bootstrapping the telemetry secret from the
  /// existing Relay enrollment. The provider owns all Relay credentials,
  /// signing identity material, and secure-storage writes.
  final TelemetryDeviceEnrollmentProvider? deviceEnrollmentProvider;

  /// Legacy compatibility value; server-provided `expiresIn` is authoritative
  /// and this value is intentionally ignored by [TelemetryClient].
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
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  });

  Future<TelemetryEnrollmentResult?> enrollDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  });

  Future<TelemetryEnrollmentResult?> rotateDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
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
    this.allowLoopbackHttp = false,
  }) : _client = client ?? HttpClient(),
       _proofFactory = proofFactory ?? const HmacTelemetryProofFactory();

  final HttpClient _client;
  final TelemetryProofFactory _proofFactory;

  /// Enables the repository's loopback-only HTTP exception for tests.
  /// Production callers must leave this disabled so telemetry requests require
  /// an HTTPS origin.
  final bool allowLoopbackHttp;

  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async {
    final uri = _resolveUri(baseUrl, TelemetryEndpoints.publicAuthPath);

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
    req.followRedirects = false;
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('Accept', 'application/json');
    req.add(utf8.encode(jsonEncode(payload)));
    final res = await req.close();
    final resBody = await utf8.decodeStream(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      try {
        final data = jsonDecode(resBody) as Map<String, dynamic>;
        final token = data['token'];
        final expiresIn = data['expiresIn'];
        if (token is! String ||
            token.isEmpty ||
            expiresIn is! num ||
            !expiresIn.isFinite ||
            expiresIn <= 0 ||
            expiresIn != expiresIn.truncate()) {
          throw const FormatException('invalid telemetry auth response');
        }
        return TelemetryAuthResult(
          token: token,
          expiresInSeconds: expiresIn.toInt(),
        );
      } on Object {
        throw const TelemetryUploadException(
          'Telemetry device authentication response is invalid',
          statusCode: 502,
        );
      }
    }
    if (res.statusCode == 401) {
      throw const TelemetryUploadException(
        'Telemetry device authentication rejected',
        statusCode: 401,
      );
    }
    throw TelemetryUploadException(
      'Telemetry device authentication failed',
      statusCode: res.statusCode,
      errorCode: _errorCodeFromBody(resBody),
    );
  }

  @override
  Future<TelemetryEnrollmentResult?> enrollDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) => _enrollDevice(
    baseUrl: baseUrl,
    deviceId: deviceId,
    request: request,
    path: TelemetryEndpoints.publicEnrollPath,
    expectedStatusCode: 201,
  );

  @override
  Future<TelemetryEnrollmentResult?> rotateDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) => _enrollDevice(
    baseUrl: baseUrl,
    deviceId: deviceId,
    request: request,
    path: TelemetryEndpoints.publicRotatePath,
    expectedStatusCode: 200,
  );

  Future<TelemetryEnrollmentResult?> _enrollDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
    required String path,
    required int expectedStatusCode,
  }) async {
    if (deviceId.isEmpty || request.deviceId != deviceId) {
      throw const TelemetryUploadException(
        'Telemetry enrollment device identity is invalid',
        statusCode: 400,
        errorCode: 'INVALID_REQUEST',
      );
    }
    if (request.transcriptPath != path) {
      throw const TelemetryUploadException(
        'Telemetry enrollment proof is bound to a different operation',
        statusCode: 400,
        errorCode: 'INVALID_REQUEST',
      );
    }

    final uri = _resolveUri(baseUrl, path);
    final payload = <String, dynamic>{
      'deviceId': request.deviceId,
      'relayCredential': request.relayCredential,
      'publicKey': request.publicKey,
      'timestamp': request.timestamp,
      'nonce': request.nonce,
      'signature': request.signature,
    };
    final req = await _client.postUrl(uri);
    req.followRedirects = false;
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('Accept', 'application/json');
    req.add(utf8.encode(jsonEncode(payload)));
    final res = await req.close();
    final resBody = await utf8.decodeStream(res);
    if (res.statusCode != expectedStatusCode) {
      throw TelemetryUploadException(
        'Telemetry enrollment request failed',
        statusCode: res.statusCode,
        errorCode: _errorCodeFromBody(resBody),
      );
    }

    try {
      final data = jsonDecode(resBody) as Map<String, dynamic>;
      final responseDeviceId = data['deviceId'];
      final secret = data['secret'];
      if (responseDeviceId != deviceId ||
          secret is! String ||
          !_isTelemetrySecret(secret)) {
        throw const FormatException('invalid telemetry enrollment response');
      }
      return TelemetryEnrollmentResult(
        deviceId: responseDeviceId as String,
        secret: secret,
      );
    } on Object {
      throw const TelemetryUploadException(
        'Telemetry enrollment response is invalid',
        statusCode: 502,
      );
    }
  }

  @override
  Future<TelemetryUploadPolicy?> fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
  }) async {
    final uri = _resolveUri(baseUrl, TelemetryEndpoints.publicPolicyPath);
    final req = await _client.getUrl(uri);
    req.followRedirects = false;
    if (authToken.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $authToken');
    }
    final res = await req.close();
    final resBody = await utf8.decodeStream(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      try {
        final data = jsonDecode(resBody) as Map<String, dynamic>;
        return TelemetryUploadPolicy.fromJson(data);
      } on Object {
        throw const TelemetryUploadException(
          'Telemetry policy response is invalid',
          statusCode: 502,
          errorCode: 'INVALID_RESPONSE',
        );
      }
    }
    throw TelemetryUploadException(
      'Telemetry policy fetch failed',
      statusCode: res.statusCode,
      errorCode: _errorCodeFromBody(resBody),
    );
  }

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    final uri = _resolveUri(baseUrl, TelemetryEndpoints.publicIngestPath);
    final req = await _client.postUrl(uri);
    req.followRedirects = false;
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
      try {
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
      } on Object {
        throw const TelemetryUploadException(
          'Telemetry upload response is invalid',
          statusCode: 502,
          errorCode: 'INVALID_RESPONSE',
        );
      }
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
      'Telemetry upload failed',
      statusCode: res.statusCode,
      retryAfterSeconds: retryAfter,
      errorCode: _errorCodeFromBody(resBody),
    );
  }

  Uri _resolveUri(String baseUrl, String path) {
    final origin = TelemetryEndpoints.validateOrigin(
      baseUrl,
      allowLoopbackHttp: allowLoopbackHttp,
    );
    if (origin == null) {
      throw const TelemetryUploadException(
        'Telemetry endpoint origin is invalid',
        statusCode: 400,
        errorCode: 'INVALID_REQUEST',
      );
    }
    return TelemetryEndpoints.resolveUri(origin.toString(), path);
  }
}

final RegExp _telemetrySecretPattern = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _telemetryErrorCodePattern = RegExp(r'^[A-Z0-9_]{1,64}$');

bool _isTelemetrySecret(String value) =>
    _telemetrySecretPattern.hasMatch(value);

/// Extract only a bounded, non-sensitive machine code from an error response.
/// Response messages are deliberately ignored because a misconfigured server
/// must never be able to echo credentials into client diagnostics.
String? _errorCodeFromBody(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final error = decoded['error'];
    final code = error is Map<String, dynamic>
        ? error['code']
        : decoded['code'];
    return _safeTelemetryErrorCode(code);
  } on Object {
    // Invalid error bodies are represented by status code only.
  }
  return null;
}

String? _safeTelemetryErrorCode(Object? value) {
  if (value is! String ||
      !_telemetryErrorCodePattern.hasMatch(value) ||
      _isTelemetrySecret(value)) {
    return null;
  }
  return value;
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
    // Keep the credential in memory for the lifetime of this client.  The
    // enrollment provider persists it for restart recovery, but a token
    // refresh must reuse the just-enrolled secret rather than re-enrolling.
    _telemetrySecret = config.deviceEnrollmentSecret;
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
  String? _telemetrySecret;
  String? _authToken;
  DateTime? _authTokenExpiresAt;
  Future<void>? _authenticationFuture;
  Future<void>? _uploadFuture;
  // All producers share one storage-write queue. This makes the durable order
  // of cross-layer spans deterministic even when callers intentionally use
  // fire-and-forget `record` calls.
  Future<void> _recordQueue = Future<void>.value();
  DateTime? _lastSyncTime;
  String? _lastSyncError;
  DateTime? _lastPolicyFetchTime;

  bool _isUploading = false;
  bool _isDisposed = false;
  Future<void>? _disposeFuture;
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

  /// Records an event using the generated definition as the only metadata
  /// source. Business callers cannot override name, version, record type,
  /// feature, or severity independently of the contract definition.
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
    // The public [record] gate runs before enqueueing. Once accepted, a
    // queued write must still drain after dispose marks the client closed.
    final now = DateTime.now().toUtc();
    final eventId = 'evt_${_uuid.v4()}';

    final errorDetail = errorCode == null
        ? null
        : TelemetryErrorDetail(
            errorCode: errorCode.code,
            category: errorCode.category,
            terminalFailure: errorCode.terminalFailure,
            message: errorMessage,
            stackTrace: stackTrace,
          );
    final record = TelemetryEventRecord(
      eventId: eventId,
      recordType: event.recordType,
      eventName: event.name,
      eventVersion: event.version,
      deviceId: config.deviceId,
      sessionId: sessionId ?? this.sessionId,
      traceId: traceId ?? _newTraceId(),
      occurredAt: now,
      feature: event.feature,
      severity: event.severity,
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

    final isHighPriorityError =
        event.severity == TelemetrySeverity.error ||
        event.severity == TelemetrySeverity.critical;
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
      if (!_hasValidToken) {
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
      _lastSyncError = _describeError(e);
      if (e is TelemetryUploadException && e.isUnauthorized) {
        _authToken = null;
        _authTokenExpiresAt = null;
      }
    }
    return false;
  }

  /// 确保存在未过期的认证令牌；缺失遥测密钥时先通过 App-owned Relay
  /// identity provider 完成一次性 enrollment。所有 enrollment/proof 异常
  /// 都在这里收敛为 fail-closed 的认证失败。
  Future<void> _ensureAuthenticated() {
    if (_hasValidToken) return Future<void>.value();

    final inFlight = _authenticationFuture;
    if (inFlight != null) return inFlight;

    final future = _authenticate();
    _authenticationFuture = future;
    return future.whenComplete(() {
      if (identical(_authenticationFuture, future)) {
        _authenticationFuture = null;
      }
    });
  }

  Future<void> _authenticate() async {
    // A failed refresh must not leave an expired token usable by a caller that
    // only checks for a non-empty string.
    _authToken = null;
    _authTokenExpiresAt = null;
    var secret = _telemetrySecret;
    if (secret == null || secret.isEmpty) {
      try {
        secret = await _enrollTelemetrySecret();
        if (secret != null && secret.isNotEmpty) {
          _telemetrySecret = secret;
        }
      } on TelemetryUploadException catch (error) {
        // Enrollment providers and transports are external boundaries. Keep
        // only machine-readable status fields; their exception messages may
        // contain platform or credential material.
        throw TelemetryUploadException(
          'Telemetry enrollment failed',
          statusCode: error.statusCode,
          retryAfterSeconds: error.retryAfterSeconds,
          errorCode: _safeTelemetryErrorCode(error.errorCode),
        );
      } on Object {
        // Provider implementations must not be able to surface secret-bearing
        // platform exception text through the diagnostics field.
        throw const TelemetryUploadException('Telemetry enrollment failed');
      }
    }

    if (secret == null || secret.isEmpty) {
      _lastSyncError = 'Missing telemetry enrollment secret';
      return;
    }

    final expEpoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 60;
    final result = await transport.authenticateDevice(
      baseUrl: config.baseUrl,
      deviceId: config.deviceId,
      platform: config.platform,
      appVersion: config.appVersion,
      authSecret: secret,
      expEpoch: expEpoch,
    );
    if (result == null ||
        result.token.isEmpty ||
        result.expiresInSeconds <= 0) {
      _lastSyncError = 'Device authentication failed';
      return;
    }

    // The server response is the source of truth. Do not substitute
    // TelemetryClientConfig.authTokenTtlSeconds here.
    _authToken = result.token;
    _authTokenExpiresAt = DateTime.now().toUtc().add(
      Duration(seconds: result.expiresInSeconds),
    );
  }

  Future<String?> _enrollTelemetrySecret() async {
    final provider = config.deviceEnrollmentProvider;
    if (provider == null) return null;

    final initialRequest = await provider.createRequest(
      baseUrl: config.baseUrl,
      deviceId: config.deviceId,
    );
    if (!_isValidEnrollmentRequest(
      initialRequest,
      expectedPath: TelemetryEndpoints.publicEnrollPath,
    )) {
      return null;
    }

    TelemetryEnrollmentResult? result;
    try {
      result = await transport.enrollDevice(
        baseUrl: config.baseUrl,
        deviceId: config.deviceId,
        request: initialRequest!,
      );
    } on TelemetryUploadException catch (error) {
      if (!error.isAlreadyEnrolled) rethrow;

      // A lost response must not retry create-only enrollment indefinitely or
      // rotate implicitly. Recovery requires a provider that can make a fresh
      // proof bound to the explicit rotate route.
      if (provider is! TelemetryDeviceEnrollmentPathProvider) return null;
      final pathProvider = provider as TelemetryDeviceEnrollmentPathProvider;
      final rotationRequest = await pathProvider.createRequestForPath(
        baseUrl: config.baseUrl,
        deviceId: config.deviceId,
        transcriptPath: TelemetryEndpoints.publicRotatePath,
      );
      if (!_isValidEnrollmentRequest(
        rotationRequest,
        expectedPath: TelemetryEndpoints.publicRotatePath,
      )) {
        return null;
      }
      result = await transport.rotateDevice(
        baseUrl: config.baseUrl,
        deviceId: config.deviceId,
        request: rotationRequest!,
      );
    }

    if (result == null ||
        result.deviceId != config.deviceId ||
        !_isTelemetrySecret(result.secret)) {
      return null;
    }

    // The provider is the only owner allowed to persist this one-time secret.
    // If secure storage fails, do not continue with an in-memory credential.
    try {
      await provider.persistSecret(result.secret);
    } on Object {
      throw const TelemetryUploadException(
        'Telemetry enrollment persistence failed',
        statusCode: 503,
        errorCode: 'TELEMETRY_AUTH_FAILED',
      );
    }
    return result.secret;
  }

  bool _isValidEnrollmentRequest(
    TelemetryDeviceEnrollmentRequest? request, {
    required String? expectedPath,
  }) {
    if (request == null ||
        request.deviceId != config.deviceId ||
        request.relayCredential.isEmpty ||
        request.publicKey.isEmpty ||
        request.timestamp <= 0 ||
        request.nonce.isEmpty ||
        request.signature.isEmpty) {
      return false;
    }
    if (expectedPath != null && request.transcriptPath != expectedPath) {
      return false;
    }
    return request.transcriptPath == TelemetryEndpoints.publicEnrollPath ||
        request.transcriptPath == TelemetryEndpoints.publicRotatePath;
  }

  /// 刷新待上传记录，内置单飞守卫、401 重认证、5xx/4xx 决策与重试退避。
  Future<void> flush() {
    if (_isDisposed || _isUploading || !activePolicy.uploadEnabled) {
      return Future<void>.value();
    }
    _isUploading = true;

    final operation = _flushWithToken();
    _uploadFuture = operation;
    return operation.whenComplete(() {
      if (identical(_uploadFuture, operation)) {
        _uploadFuture = null;
      }
      _isUploading = false;
    });
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
    if (!_hasValidToken) {
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
        if (!_hasValidToken) {
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
          await _handleUploadFailure(pending, retryError);
          return;
        }
      } else if (e.isPermanentClientError) {
        // 永久 4xx（如 400 无效 schema）：标记 rejected，停止自动重试。
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
        await storage.applyAckResults(results);
        _lastSyncError = _describeError(e);
        return;
      } else {
        // 5xx / 503 / 连接错误：累计 retryCount，指数退避 + 抖动。
        await _handleUploadFailure(pending, e);
        return;
      }
    } catch (e) {
      // 连接层及其他异常按服务器错误处理。
      await _handleUploadFailure(
        pending,
        TelemetryUploadException(_describeError(e)),
      );
    }
  }

  Future<void> _handleUploadFailure(
    List<TelemetryEventRecord> records,
    TelemetryUploadException error,
  ) async {
    _lastSyncError = _describeError(error);
    if (!error.isPermanentClientError) {
      // 递增 retryCount 并持久化，供后续退避决策使用。
      await storage.applyRetryCount(
        records.map((r) => r.eventId).toList(),
        increment: 1,
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
    if (error is TelemetryUploadException) {
      final code = _safeTelemetryErrorCode(error.errorCode);
      final status = error.statusCode;
      if (code != null && status != null) {
        return 'Telemetry request failed ($code, HTTP $status)';
      }
      if (code != null) return 'Telemetry request failed ($code)';
      if (status != null) {
        return 'Telemetry request failed (HTTP $status)';
      }
      return 'Telemetry request failed';
    }
    if (error is HttpException) return 'Telemetry connection error';
    return 'Telemetry operation failed';
  }

  /// 以原始身份（eventId/sessionId/traceId）重放全部本地记录。
  Future<int> replayAllLocalRecords() {
    if (_isDisposed || _isUploading) return Future<int>.value(0);
    _isUploading = true;

    final operation = _replayAllLocalRecords();
    final trackedOperation = operation.then<void>((_) {});
    _uploadFuture = trackedOperation;
    return operation.whenComplete(() {
      if (identical(_uploadFuture, trackedOperation)) {
        _uploadFuture = null;
      }
      _isUploading = false;
    });
  }

  Future<int> _replayAllLocalRecords() async {
    try {
      final allRecords = await storage.fetchAllForReplay();
      if (allRecords.isEmpty) return 0;

      try {
        await _ensureAuthenticated();
      } catch (e) {
        _lastSyncError = _describeError(e);
        return 0;
      }
      if (!_hasValidToken) {
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
    final health =
        storage.cachedHealthStats ??
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

  /// Stops new work, drains authentication/uploads, then closes storage.
  /// Repeated calls share the same in-flight future and close storage once.
  Future<void> dispose() {
    final inFlight = _disposeFuture;
    if (inFlight != null) return inFlight;

    _isDisposed = true;
    _flushTimer?.cancel();
    _policyTimer?.cancel();

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
        // Authentication failures are already reflected in client diagnostics;
        // disposal must still drain the operation and close storage.
      }
    }

    final upload = _uploadFuture;
    if (upload != null) {
      try {
        await upload;
      } on Object {
        // Upload failures are reflected in pending records/diagnostics;
        // disposal must still close storage after the operation settles.
      }
    }

    // A producer may have queued a record immediately before disposal. Drain
    // those writes before closing the storage so no accepted span is lost or
    // reordered at the lifecycle boundary.
    await _recordQueue;
    final uploadAfterRecords = _uploadFuture;
    if (uploadAfterRecords != null) {
      try {
        await uploadAfterRecords;
      } on Object {
        // The upload path records its own diagnostic state; storage still
        // closes after the final queued write settles.
      }
    }
    await storage.close();
  }
}
