part of 'telemetry_client.dart';

/// Abstract transport contract for telemetry network operations.
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

/// Authentication proof factory, injectable for deterministic tests.
abstract class TelemetryProofFactory {
  const TelemetryProofFactory();

  /// Signs `telemetry:auth:$deviceId:$expEpoch` with HMAC-SHA256.
  String sign({
    required String enrollmentSecret,
    required String deviceId,
    required int expEpoch,
  });
}

/// Default HMAC-SHA256 proof implementation.
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

final RegExp _telemetrySecretPattern = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _telemetryErrorCodePattern = RegExp(r'^[A-Z0-9_]{1,64}$');

bool _isTelemetrySecret(String value) =>
    _telemetrySecretPattern.hasMatch(value);

/// Extract only a bounded, non-sensitive machine code from an error response.
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

bool _isKnownTelemetryAckStatus(String status) =>
    status == 'accepted' || status == 'already_seen' || status == 'rejected';
