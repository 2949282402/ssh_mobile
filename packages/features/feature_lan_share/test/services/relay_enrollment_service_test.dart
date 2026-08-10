// Relay enrollment 的 Feature contract 测试；Dart 不承载 Relay 数据面。

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
}

final class _FakeBootstrapClient implements BootstrapClient {
  const _FakeBootstrapClient({required this.onEnroll});

  final DeviceEnrollment Function(Uri endpoint, EnrollmentRequest request)
  onEnroll;

  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async =>
      const SdkSuccess(BootstrapMetadata(protocolVersion: 1));

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  ) async => SdkSuccess(onEnroll(endpoint, request));
}
