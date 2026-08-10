// v1 Relay enrollment 范围测试；Dart 不承载 Relay 数据面。

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/relay/relay_enrollment_service.dart';

/// 执行 v1 Relay enrollment 范围测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('relay credential is scoped to endpoint and device identity', () async {
    late Uri requestedEndpoint;
    final endpoint = Uri.parse('https://relay.example.test:8443');
    final service = RelayEnrollmentService(
      currentDeviceId: 'device-a',
      enrollmentRequester: (requestEndpoint, payload) async {
        requestedEndpoint = requestEndpoint;
        expect(payload['device_id'], 'device-a');
        expect(payload['protocol_version'], 1);
        return {
          'credential': 'signed-credential',
          'expires_at':
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          'server_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'protocol_version': 1,
        };
      },
    );
    addTearDown(service.dispose);
    final enrollment = await service.enroll(
      RelaySettings(endpoint: endpoint),
      '0123456789abcdef',
    );
    expect(enrollment, isA<NetworkSuccess<void>>());

    expect(requestedEndpoint.path, '/v1/devices/enroll');
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
  });

  test(
    'relay enrollment rejects HTTP and mismatched server protocol',
    () async {
      final service = RelayEnrollmentService(
        currentDeviceId: 'device-a',
        enrollmentRequester: (_, _) async => {
          'credential': 'signed-credential',
          'expires_at':
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          'server_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'protocol_version': RelayEnrollmentService.protocolVersion + 1,
        },
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
    },
  );
}
