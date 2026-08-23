// Real Dart bootstrap traffic through AppSdkRequestExecutor → Caddy → Go Relay.
//
// This is intentionally an integration test, not a contract test: the
// executor and JsonBootstrapClient are production implementations and the
// endpoint/token are supplied by scripts/client_backend_e2e.sh.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/app/network_sdk_adapters.dart';

void main() {
  final baseUrl = Platform.environment['CLIENT_BACKEND_E2E_BASE_URL'] ?? '';
  final enrollmentToken = Platform.environment['RELAY_ENROLLMENT_TOKEN'] ?? '';

  test('real bootstrap enrollment, refresh, and typed failures', () async {
    expect(
      baseUrl,
      isNotEmpty,
      reason: 'CLIENT_BACKEND_E2E_BASE_URL is required for live E2E',
    );
    expect(
      enrollmentToken,
      isNotEmpty,
      reason: 'RELAY_ENROLLMENT_TOKEN is required for live E2E',
    );

    final endpoint = Uri.parse(baseUrl);
    expect(endpoint.scheme, anyOf('http', 'https'));
    expect(endpoint.path, anyOf('', '/'));

    const executor = AppSdkRequestExecutor();
    final bootstrap = JsonBootstrapClient(executor: executor);
    final probe = await bootstrap.probe(endpoint);
    final probeMetadata = _success(probe, 'Relay health probe');
    expect(probeMetadata.protocolVersion, 1);

    final algorithm = Ed25519();
    final deviceA = await _newDevice(algorithm, 'e2e-dart-a');
    final deviceB = await _newDevice(algorithm, 'e2e-dart-b');
    final invalidTokenDevice = await _newDevice(algorithm, 'e2e-dart-invalid');

    final enrollmentA = await bootstrap.enroll(
      endpoint,
      EnrollmentRequest(
        deviceId: deviceA.id,
        identityPublicKey: deviceA.publicKey,
        enrollmentToken: enrollmentToken,
        platform: 'dart-e2e',
      ),
    );
    final dataA = _success(enrollmentA, 'Dart device A enrollment');
    _assertEnrollment(dataA, deviceA.id);

    final enrollmentB = await bootstrap.enroll(
      endpoint,
      EnrollmentRequest(
        deviceId: deviceB.id,
        identityPublicKey: deviceB.publicKey,
        enrollmentToken: enrollmentToken,
        platform: 'dart-e2e',
      ),
    );
    final dataB = _success(enrollmentB, 'Dart device B enrollment');
    _assertEnrollment(dataB, deviceB.id);
    expect(dataA.relayCredential, isNot(dataB.relayCredential));

    final badEnrollment = await bootstrap.enroll(
      endpoint,
      EnrollmentRequest(
        deviceId: invalidTokenDevice.id,
        identityPublicKey: invalidTokenDevice.publicKey,
        enrollmentToken: 'invalid-token-for-e2e',
      ),
    );
    final badEnrollmentFailure = _failure(
      badEnrollment,
      'invalid enrollment token',
    );
    expect(badEnrollmentFailure.code, NetworkErrorCode.authenticationFailed);

    final refreshA = await bootstrap.refresh(
      endpoint,
      await _refreshRequest(algorithm, deviceA),
    );
    final refreshed = _success(refreshA, 'Dart device A credential refresh');
    _assertEnrollment(refreshed, deviceA.id);
    // The Relay credential is a deterministic signed claim for the same
    // device/expiry second, so a refresh may legitimately return the same
    // bearer string when it happens within one second.
    expect(refreshed.relayCredential, isNotEmpty);
    expect(refreshed.expiresAt.isAfter(refreshed.serverTime), isTrue);

    final invalidProof = await bootstrap.refresh(
      endpoint,
      RefreshRequest(
        deviceId: deviceA.id,
        identityPublicKey: deviceA.publicKey,
        nonce: _nonce(),
        signature: base64UrlEncode(List<int>.filled(64, 0)).replaceAll('=', ''),
      ),
    );
    final invalidProofFailure = _failure(invalidProof, 'invalid refresh proof');
    expect(invalidProofFailure.code, NetworkErrorCode.authenticationFailed);

    final unknownDevice = await _newDevice(algorithm, 'e2e-dart-unknown');
    final missingEnrollment = await bootstrap.refresh(
      endpoint,
      await _refreshRequest(algorithm, unknownDevice),
    );
    final missingEnrollmentFailure = _failure(
      missingEnrollment,
      'refresh for an unenrolled device',
    );
    expect(missingEnrollmentFailure.code, NetworkErrorCode.noRoute);

    final unsupportedVersion = await bootstrap.enroll(
      endpoint,
      EnrollmentRequest(
        deviceId: 'e2e-dart-unsupported-version',
        identityPublicKey: invalidTokenDevice.publicKey,
        enrollmentToken: enrollmentToken,
        protocolVersion: 99,
      ),
    );
    final unsupportedVersionFailure = _failure(
      unsupportedVersion,
      'unsupported bootstrap protocol version',
    );
    expect(unsupportedVersionFailure.code, NetworkErrorCode.invalidArgument);
  });
}

final class _Device {
  const _Device({
    required this.id,
    required this.keyPair,
    required this.publicKey,
  });

  final String id;
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
}

Future<_Device> _newDevice(Ed25519 algorithm, String id) async {
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  return _Device(
    id: id,
    keyPair: keyPair,
    publicKey: Uint8List.fromList(publicKey.bytes),
  );
}

Future<RefreshRequest> _refreshRequest(
  Ed25519 algorithm,
  _Device device,
) async {
  final nonce = _nonce();
  final transcript = 'POST\n/v1/devices/refresh\n$nonce';
  final signature = await algorithm.sign(
    utf8.encode(transcript),
    keyPair: device.keyPair,
  );
  return RefreshRequest(
    deviceId: device.id,
    identityPublicKey: device.publicKey,
    nonce: nonce,
    signature: base64UrlEncode(signature.bytes).replaceAll('=', ''),
  );
}

String _nonce() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

T _success<T>(SdkResult<T> result, String operation) {
  expect(result, isA<SdkSuccess<T>>(), reason: '$operation should succeed');
  return (result as SdkSuccess<T>).data;
}

NetworkError _failure<T>(SdkResult<T> result, String operation) {
  expect(result, isA<SdkFailure<T>>(), reason: '$operation should fail');
  return (result as SdkFailure<T>).error;
}

void _assertEnrollment(DeviceEnrollment enrollment, String deviceId) {
  expect(enrollment.deviceId, deviceId);
  expect(enrollment.relayCredential, isNotEmpty);
  expect(enrollment.protocolVersion, 1);
  expect(enrollment.expiresAt.isAfter(enrollment.serverTime), isTrue);
}
