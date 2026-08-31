part of 'telemetry_client.dart';

mixin _TelemetryClientAuthentication on _TelemetryClientBase {
  /// Ensures a non-expired bearer token, sharing concurrent authentication.
  @override
  Future<void> _ensureAuthenticated() {
    if (!_telemetryEnabled) return Future<void>.value();
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
    if (!_telemetryEnabled) return;
    // A failed refresh must not leave an expired token usable by callers.
    _clearAuthToken();
    var secret = _telemetrySecret;
    if (secret == null || secret.isEmpty) {
      if (!_telemetryEnabled) return;
      try {
        secret = await _enrollTelemetrySecret();
        if (!_telemetryEnabled) return;
        if (secret != null && secret.isNotEmpty) _telemetrySecret = secret;
      } on TelemetryUploadException catch (error) {
        // External enrollment messages may contain credential material. Keep
        // only machine-readable status fields in diagnostics.
        throw TelemetryUploadException(
          'Telemetry enrollment failed',
          statusCode: error.statusCode,
          retryAfterSeconds: error.retryAfterSeconds,
          errorCode: _safeTelemetryErrorCode(error.errorCode),
        );
      } on Object {
        throw const TelemetryUploadException('Telemetry enrollment failed');
      }
    }

    if (secret == null || secret.isEmpty) {
      _lastSyncError = 'Missing telemetry enrollment secret';
      return;
    }

    if (!_telemetryEnabled) return;

    final expEpoch = _now().millisecondsSinceEpoch ~/ 1000 + 60;
    final result = await transport.authenticateDevice(
      baseUrl: config.baseUrl,
      deviceId: config.deviceId,
      platform: config.platform,
      appVersion: config.appVersion,
      authSecret: secret,
      expEpoch: expEpoch,
    );
    if (!_telemetryEnabled) return;
    if (result == null ||
        result.token.isEmpty ||
        result.expiresInSeconds <= 0) {
      _lastSyncError = 'Device authentication failed';
      return;
    }

    // The server response, not authTokenTtlSeconds, is authoritative.
    _setAuthToken(
      result.token,
      _now().add(Duration(seconds: result.expiresInSeconds)),
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

      // Recovery requires an explicit rotate proof; create-only providers
      // cannot silently rotate after a lost enrollment response.
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

    // The provider exclusively owns persistence of this one-time secret.
    try {
      await provider.persistSecret(result.secret);
    } on Object {
      throw TelemetryUploadException(
        'Telemetry enrollment persistence failed',
        statusCode: 503,
        errorCode: TelemetryErrorCodes.telemetryAuthFailed.code,
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
}
