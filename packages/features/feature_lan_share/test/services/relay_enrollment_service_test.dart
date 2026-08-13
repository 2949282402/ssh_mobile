// Relay enrollment 的 Feature contract 测试；Dart 不承载 Relay 数据面。

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('relay credential is scoped to endpoint and device identity', () async {
    final endpoint = Uri.parse('https://relay.example.test:8443');
    final service = RelayEnrollmentService(
      currentDeviceId: 'device-a',
      bootstrapClient: _FakeBootstrapClient(
        onEnroll: (requestEndpoint, request) {
          expect(requestEndpoint, endpoint);
          expect(request.deviceId, 'device-a');
          expect(request.protocolVersion, 1);
          return DeviceEnrollment(
            deviceId: request.deviceId,
            relayCredential: 'signed-credential',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
            serverTime: DateTime.now(),
            protocolVersion: 1,
          );
        },
      ),
    );
    addTearDown(service.dispose);

    final enrollment = await service.enroll(
      RelaySettings(endpoint: endpoint),
      '0123456789abcdef',
    );
    expect(enrollment, isA<NetworkSuccess<void>>());
    expect(await service.isEnrolled(RelaySettings(endpoint: endpoint)), isTrue);
    expect(
      await service.isEnrolled(
        RelaySettings(endpoint: Uri.parse('https://other.example.test')),
      ),
      isFalse,
    );

    final native = await service.nativeConfiguration(
      RelaySettings(endpoint: endpoint),
    );
    expect(native, isNotNull);
    expect(native!.endpoint, endpoint);
    expect(native.credential, 'signed-credential');
    expect(native.signingSeed, hasLength(32));

    await service.clearEnrollment();
    expect(
      await service.isEnrolled(RelaySettings(endpoint: endpoint)),
      isFalse,
    );
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: 'relay_device_credential_v1'), isNull);
    expect(await storage.read(key: 'relay_device_signing_seed_v1'), isNotNull);
  });

  test('relay enrollment rejects invalid endpoint and protocol', () async {
    final service = RelayEnrollmentService(
      currentDeviceId: 'device-a',
      bootstrapClient: _FakeBootstrapClient(
        onEnroll: (_, request) => DeviceEnrollment(
          deviceId: request.deviceId,
          relayCredential: 'signed-credential',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          serverTime: DateTime.now(),
          protocolVersion: RelayEnrollmentService.protocolVersion + 1,
        ),
      ),
    );
    addTearDown(service.dispose);

    final invalidEndpoint = await service.enroll(
      RelaySettings(endpoint: Uri.parse('http://relay.example.test')),
      '0123456789abcdef',
    );
    expect(invalidEndpoint, isA<NetworkFailure<void>>());
    expect(
      (invalidEndpoint as NetworkFailure<void>).error.code,
      NetworkErrorCode.invalidArgument,
    );

    final mismatchedVersion = await service.enroll(
      RelaySettings(endpoint: Uri.parse('https://relay.example.test')),
      '0123456789abcdef',
    );
    expect(mismatchedVersion, isA<NetworkFailure<void>>());
    expect(
      (mismatchedVersion as NetworkFailure<void>).error.code,
      NetworkErrorCode.relayError,
    );
  });

  test(
    'refreshCredential signs the transcript and stores a new credential',
    () async {
      final endpoint = Uri.parse('https://relay.example.test');
      RefreshRequest? captured;
      final service = RelayEnrollmentService(
        currentDeviceId: 'device-a',
        bootstrapClient: _FakeBootstrapClient(
          onEnroll: (requestEndpoint, request) => DeviceEnrollment(
            deviceId: request.deviceId,
            relayCredential: 'signed-credential',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
            serverTime: DateTime.now(),
            protocolVersion: 1,
          ),
          onRefresh: (requestEndpoint, request) {
            expect(requestEndpoint, endpoint);
            captured = request;
            return SdkSuccess(
              DeviceEnrollment(
                deviceId: request.deviceId,
                relayCredential: 'refreshed-credential',
                expiresAt: DateTime.now().add(const Duration(hours: 1)),
                serverTime: DateTime.now(),
                protocolVersion: 1,
              ),
            );
          },
        ),
      );
      addTearDown(service.dispose);

      await service.enroll(
        RelaySettings(endpoint: endpoint),
        '0123456789abcdef',
      );
      final refresh = await service.refreshCredential(
        RelaySettings(endpoint: endpoint),
      );
      expect(refresh, isA<NetworkSuccess<void>>());
      expect(captured, isNotNull);
      final request = captured!;
      expect(request.deviceId, 'device-a');
      expect(request.identityPublicKey, hasLength(32));
      expect(
        base64Url.decode(base64Url.normalize(request.nonce)),
        hasLength(32),
      );
      final signatureBytes = base64Url.decode(
        base64Url.normalize(request.signature),
      );
      expect(signatureBytes, hasLength(64));
      final valid = await Ed25519().verify(
        utf8.encode('POST\n/v1/devices/refresh\n${request.nonce}'),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(
            request.identityPublicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );
      expect(valid, isTrue);

      expect(
        await service.isEnrolled(RelaySettings(endpoint: endpoint)),
        isTrue,
      );
      final native = await service.nativeConfiguration(
        RelaySettings(endpoint: endpoint),
      );
      expect(native, isNotNull);
      expect(native!.credential, 'refreshed-credential');
    },
  );

  test(
    'refreshCredential maps SDK failures without clobbering the credential',
    () async {
      final endpoint = Uri.parse('https://relay.example.test');
      final service = RelayEnrollmentService(
        currentDeviceId: 'device-a',
        bootstrapClient: _FakeBootstrapClient(
          onEnroll: (requestEndpoint, request) => DeviceEnrollment(
            deviceId: request.deviceId,
            relayCredential: 'original-credential',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
            serverTime: DateTime.now(),
            protocolVersion: 1,
          ),
          onRefresh: (requestEndpoint, request) => const SdkFailure(
            NetworkError(
              code: NetworkErrorCode.noRoute,
              message: 'Relay device is not enrolled.',
              operation: NetworkOperation.refreshCredential,
            ),
          ),
        ),
      );
      addTearDown(service.dispose);

      await service.enroll(
        RelaySettings(endpoint: endpoint),
        '0123456789abcdef',
      );
      final refresh = await service.refreshCredential(
        RelaySettings(endpoint: endpoint),
      );
      expect(refresh, isA<NetworkFailure<void>>());
      expect(
        (refresh as NetworkFailure<void>).error.code,
        NetworkErrorCode.noRoute,
      );
      expect(refresh.error.operation, NetworkOperation.refreshCredential);
      // 刷新失败不得覆盖既有凭据。
      final native = await service.nativeConfiguration(
        RelaySettings(endpoint: endpoint),
      );
      expect(native, isNotNull);
      expect(native!.credential, 'original-credential');
    },
  );
}

final class _FakeBootstrapClient implements BootstrapClient {
  const _FakeBootstrapClient({required this.onEnroll, this.onRefresh});

  final DeviceEnrollment Function(Uri endpoint, EnrollmentRequest request)
  onEnroll;
  final SdkResult<DeviceEnrollment> Function(
    Uri endpoint,
    RefreshRequest request,
  )?
  onRefresh;

  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async =>
      const SdkSuccess(BootstrapMetadata(protocolVersion: 1));

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  ) async => SdkSuccess(onEnroll(endpoint, request));

  @override
  Future<SdkResult<DeviceEnrollment>> refresh(
    Uri endpoint,
    RefreshRequest request,
  ) async {
    final handler = onRefresh;
    if (handler == null) {
      return SdkSuccess(
        DeviceEnrollment(
          deviceId: request.deviceId,
          relayCredential: 'refreshed-credential',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          serverTime: DateTime.now(),
          protocolVersion: 1,
        ),
      );
    }
    return handler(endpoint, request);
  }
}
