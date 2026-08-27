import 'dart:convert';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_factory.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'creates an enrollment proof from the existing Relay identity',
    () async {
      final storage = _MemorySecureStorage();
      final seed = Uint8List.fromList(List<int>.filled(32, 7));
      final relay = _FakeRelayEnrollment(
        configuration: RelayNativeConfiguration(
          endpoint: Uri.parse('https://relay.example.test'),
          credential: 'existing-relay-credential',
          signingSeed: seed,
        ),
      );
      final provider = RelayTelemetryEnrollmentProvider(
        relayEnrollment: relay,
        expectedDeviceId: 'device-a',
        secureStorage: storage,
      );

      final request = await provider.createRequest(
        baseUrl: 'https://relay.example.test',
        deviceId: 'device-a',
      );

      expect(request, isNotNull);
      expect(request!.deviceId, 'device-a');
      expect(request.relayCredential, 'existing-relay-credential');
      expect(request.transcriptPath, TelemetryEndpoints.publicEnrollPath);
      expect(
        base64Url.decode(base64Url.normalize(request.publicKey)),
        hasLength(32),
      );
      expect(
        base64Url.decode(base64Url.normalize(request.nonce)),
        hasLength(32),
      );

      final signature = base64Url.decode(
        base64Url.normalize(request.signature),
      );
      final valid = await Ed25519().verify(
        utf8.encode(
          'POST\n${TelemetryEndpoints.publicEnrollPath}\n'
          '${request.timestamp}\n${request.nonce}',
        ),
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(
            base64Url.decode(base64Url.normalize(request.publicKey)),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      expect(valid, isTrue);
      expect(await storage.read(key: telemetryDeviceSecretKey), isNull);
    },
  );

  test(
    'binds recovery proofs to rotate and refreshes an expired Relay credential',
    () async {
      final storage = _MemorySecureStorage();
      final seed = Uint8List.fromList(List<int>.filled(32, 9));
      final relay = _FakeRelayEnrollment(
        configuration: RelayNativeConfiguration(
          endpoint: Uri.parse('https://relay.example.test'),
          credential: 'refreshed-relay-credential',
          signingSeed: seed,
        ),
        hasStored: true,
        firstConfigurationUnavailable: true,
      );
      final provider = RelayTelemetryEnrollmentProvider(
        relayEnrollment: relay,
        expectedDeviceId: 'device-a',
        secureStorage: storage,
      );

      final request = await provider.createRequestForPath(
        baseUrl: 'https://relay.example.test',
        deviceId: 'device-a',
        transcriptPath: TelemetryEndpoints.publicRotatePath,
      );

      expect(request, isNotNull);
      expect(request!.transcriptPath, TelemetryEndpoints.publicRotatePath);
      expect(relay.refreshCalls, 1);
      expect(
        await provider.createRequestForPath(
          baseUrl: 'https://relay.example.test',
          deviceId: 'device-a',
          transcriptPath: '/api/v1/telemetry/unknown',
        ),
        isNull,
      );

      final signature = base64Url.decode(
        base64Url.normalize(request.signature),
      );
      final valid = await Ed25519().verify(
        utf8.encode(
          'POST\n${TelemetryEndpoints.publicRotatePath}\n'
          '${request.timestamp}\n${request.nonce}',
        ),
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(
            base64Url.decode(base64Url.normalize(request.publicKey)),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      expect(valid, isTrue);
    },
  );

  test(
    'persists only valid one-time telemetry secrets in secure storage',
    () async {
      final storage = _MemorySecureStorage();
      final provider = RelayTelemetryEnrollmentProvider(
        relayEnrollment: _FakeRelayEnrollment(),
        secureStorage: storage,
      );
      final secret = List<String>.filled(64, 'a').join();

      await provider.persistSecret(secret);

      expect(await storage.read(key: telemetryDeviceSecretKey), secret);
      await expectLater(
        provider.persistSecret('not-a-telemetry-secret'),
        throwsArgumentError,
      );
    },
  );

  test(
    'fails closed when the Relay identity or endpoint is unavailable',
    () async {
      final provider = RelayTelemetryEnrollmentProvider(
        relayEnrollment: _FakeRelayEnrollment(),
        expectedDeviceId: 'device-a',
      );

      expect(
        await provider.createRequest(
          baseUrl: 'http://relay.example.test',
          deviceId: 'device-a',
        ),
        isNull,
      );
      expect(
        await provider.createRequest(
          baseUrl: 'https://relay.example.test',
          deviceId: 'other-device',
        ),
        isNull,
      );
    },
  );

  test('allows HTTP only for the repository loopback E2E endpoint', () async {
    final relay = _FakeRelayEnrollment(
      configuration: RelayNativeConfiguration(
        endpoint: Uri.parse('http://127.0.0.1:8080'),
        credential: 'loopback-relay-credential',
        signingSeed: Uint8List.fromList(List<int>.filled(32, 3)),
      ),
    );
    final provider = RelayTelemetryEnrollmentProvider(
      relayEnrollment: relay,
      expectedDeviceId: 'device-a',
      allowLoopbackHttp: true,
    );

    expect(
      await provider.createRequest(
        baseUrl: 'http://127.0.0.1:8080',
        deviceId: 'device-a',
      ),
      isNotNull,
    );
    expect(
      await provider.createRequest(
        baseUrl: 'http://relay.example.test:8080',
        deviceId: 'device-a',
      ),
      isNull,
    );
  });
}

final class _MemorySecureStorage implements FlutterSecureStorage {
  final Map<String, String> values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(key == null ? null : values[key]);
      case #write:
        final value = invocation.namedArguments[#value] as String?;
        if (key != null && value != null) values[key] = value;
        return Future<void>.value();
      case #delete:
        if (key != null) values.remove(key);
        return Future<void>.value();
      default:
        throw UnimplementedError('Unexpected secure-storage call: $invocation');
    }
  }
}

final class _FakeRelayEnrollment implements LanRelayEnrollmentPort {
  _FakeRelayEnrollment({
    this.configuration,
    this.hasStored = false,
    this.firstConfigurationUnavailable = false,
  });

  final RelayNativeConfiguration? configuration;
  final bool hasStored;
  final bool firstConfigurationUnavailable;
  int refreshCalls = 0;
  int nativeConfigurationCalls = 0;

  @override
  Future<NetworkResult<void>> enroll(
    RelaySettings settings,
    String enrollmentToken,
  ) async => const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> refreshCredential(RelaySettings settings) async {
    refreshCalls++;
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<bool> hasStoredCredential(RelaySettings settings) async => hasStored;

  @override
  Future<bool> isEnrolled(RelaySettings settings) async =>
      configuration != null;

  @override
  Future<RelayNativeConfiguration?> nativeConfiguration(
    RelaySettings settings,
  ) async {
    nativeConfigurationCalls++;
    if (firstConfigurationUnavailable && nativeConfigurationCalls == 1) {
      return null;
    }
    return configuration;
  }

  @override
  Future<void> clearEnrollment() async {}

  @override
  Future<void> dispose() async {}
}
