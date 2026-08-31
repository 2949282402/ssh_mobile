part of 'telemetry_client.dart';

/// Must stay aligned with the relay's `MaxRequestBodyBytes` boundary.
const int telemetryMaxUploadBodyBytes = 1 << 20;

/// Standard `dart:io` HTTPS transport for telemetry operations.
class HttpTelemetryTransport implements TelemetryTransport {
  HttpTelemetryTransport({
    HttpClient? client,
    TelemetryProofFactory? proofFactory,
    this.allowLoopbackHttp = false,
    this.connectionTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 30),
  }) : _client = client ?? HttpClient(),
       _proofFactory = proofFactory ?? const HmacTelemetryProofFactory() {
    if (connectionTimeout.compareTo(Duration.zero) <= 0) {
      throw ArgumentError.value(
        connectionTimeout,
        'connectionTimeout',
        'must be greater than zero',
      );
    }
    if (requestTimeout.compareTo(Duration.zero) <= 0) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be greater than zero',
      );
    }
    _client.connectionTimeout = connectionTimeout;
  }

  final HttpClient _client;
  final TelemetryProofFactory _proofFactory;

  /// Enables the loopback-only HTTP exception used by tests.
  final bool allowLoopbackHttp;

  /// Bounds DNS/connect establishment for every request.
  final Duration connectionTimeout;

  /// Bounds request writes, response headers, and response-body reads.
  final Duration requestTimeout;

  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) {
    HttpClientRequest? request;
    return _withRequestTimeout(
      () => _authenticateDevice(
        baseUrl: baseUrl,
        deviceId: deviceId,
        platform: platform,
        appVersion: appVersion,
        authSecret: authSecret,
        expEpoch: expEpoch,
        onRequestCreated: (created) => request = created,
      ),
      onTimeout: () => request?.abort(),
    );
  }

  Future<TelemetryAuthResult?> _authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
    required void Function(HttpClientRequest request) onRequestCreated,
  }) async {
    final uri = _resolveUri(baseUrl, TelemetryEndpoints.publicAuthPath);
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
    onRequestCreated(req);
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
  }) {
    HttpClientRequest? activeRequest;
    return _withRequestTimeout(
      () => _performEnrollment(
        baseUrl: baseUrl,
        deviceId: deviceId,
        request: request,
        path: path,
        expectedStatusCode: expectedStatusCode,
        onRequestCreated: (created) => activeRequest = created,
      ),
      onTimeout: () => activeRequest?.abort(),
    );
  }

  Future<TelemetryEnrollmentResult?> _performEnrollment({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
    required String path,
    required int expectedStatusCode,
    required void Function(HttpClientRequest request) onRequestCreated,
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
    onRequestCreated(req);
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
  }) {
    HttpClientRequest? request;
    return _withRequestTimeout(
      () => _fetchRemotePolicy(
        baseUrl: baseUrl,
        authToken: authToken,
        onRequestCreated: (created) => request = created,
      ),
      onTimeout: () => request?.abort(),
    );
  }

  Future<TelemetryUploadPolicy?> _fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
    required void Function(HttpClientRequest request) onRequestCreated,
  }) async {
    final uri = _resolveUri(baseUrl, TelemetryEndpoints.publicPolicyPath);
    final req = await _client.getUrl(uri);
    onRequestCreated(req);
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
  }) {
    HttpClientRequest? request;
    return _withRequestTimeout(
      () => _uploadBatch(
        baseUrl: baseUrl,
        authToken: authToken,
        deviceId: deviceId,
        records: records,
        onRequestCreated: (created) => request = created,
      ),
      onTimeout: () => request?.abort(),
    );
  }

  Future<TelemetryBatchUploadResult> _uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
    required void Function(HttpClientRequest request) onRequestCreated,
  }) async {
    final payload = jsonEncode({
      'records': records.map((r) => r.toJson()).toList(),
    });
    final payloadBytes = utf8.encode(payload);
    if (payloadBytes.length > telemetryMaxUploadBodyBytes) {
      throw const TelemetryUploadException(
        'Telemetry upload request body is too large',
        statusCode: 413,
        errorCode: 'PAYLOAD_TOO_LARGE',
      );
    }
    final uri = _resolveUri(baseUrl, TelemetryEndpoints.publicIngestPath);
    final req = await _client.postUrl(uri);
    onRequestCreated(req);
    req.followRedirects = false;
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('X-Device-Id', deviceId);
    if (authToken.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $authToken');
    }
    req.add(payloadBytes);
    final res = await req.close();
    final resBody = await utf8.decodeStream(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      try {
        final data = jsonDecode(resBody) as Map<String, dynamic>;
        final rawResults = data['results'];
        if (rawResults is! List<dynamic>) {
          throw const FormatException('missing telemetry upload results');
        }
        final expectedIds = records.map((record) => record.eventId).toSet();
        final seenIds = <String>{};
        final resultsJson = rawResults.map((item) {
          if (item is! Map) {
            throw const FormatException('invalid telemetry upload result');
          }
          final result = Map<String, dynamic>.from(item);
          final eventId = result['eventId'];
          final status = result['status'];
          if (eventId is! String ||
              eventId.isEmpty ||
              status is! String ||
              !_isKnownTelemetryAckStatus(status) ||
              !expectedIds.contains(eventId) ||
              !seenIds.add(eventId)) {
            throw const FormatException('invalid telemetry upload ACK');
          }
          return TelemetryAckResult.fromJson(result);
        }).toList();
        return TelemetryBatchUploadResult(ackResults: resultsJson);
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
      if (header != null) retryAfter = int.tryParse(header);
    }

    throw TelemetryUploadException(
      'Telemetry upload failed',
      statusCode: res.statusCode,
      retryAfterSeconds: retryAfter,
      errorCode: _errorCodeFromBody(resBody),
    );
  }

  Future<T> _withRequestTimeout<T>(
    Future<T> Function() operation, {
    required void Function() onTimeout,
  }) async {
    try {
      return await operation().timeout(requestTimeout);
    } on TelemetryUploadException {
      rethrow;
    } on TimeoutException {
      try {
        onTimeout();
      } on Object {
        // Aborting an already-closed request is best effort.
      }
      throw TelemetryUploadException(
        'Telemetry request timed out',
        errorCode: TelemetryErrorCodes.telemetryNetworkError.code,
      );
    } on Object {
      try {
        onTimeout();
      } on Object {
        // The request may already have completed or failed at the socket.
      }
      throw TelemetryUploadException(
        'Telemetry request failed',
        errorCode: TelemetryErrorCodes.telemetryNetworkError.code,
      );
    }
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
