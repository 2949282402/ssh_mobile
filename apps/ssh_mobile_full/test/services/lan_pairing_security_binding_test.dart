import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const deviceId = 'peer-device';
  const peerFingerprint =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const otherFingerprint =
      '2222222222222222222222222222222222222222222222222222222222222222';
  const localFingerprint =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const token = 'outbound-access-token';

  late LanSecurityService security;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    security = LanSecurityService();
  });

  test('fresh reciprocal proof is fully bound and one-use', () async {
    await security.storeOutboundAccessToken(deviceId, token);
    await security.storePeerCertificateFingerprint(deviceId, peerFingerprint);
    security.markFreshOutboundPairProof(
      deviceId: deviceId,
      peerFingerprint: peerFingerprint,
      localFingerprint: localFingerprint,
      accessToken: token,
    );

    expect(
      await security.consumeFreshOutboundPinProof(
        deviceId: deviceId,
        peerFingerprint: otherFingerprint,
        localFingerprint: localFingerprint,
      ),
      isFalse,
    );
    expect(
      await security.consumeFreshOutboundPinProof(
        deviceId: deviceId,
        peerFingerprint: peerFingerprint,
        localFingerprint: localFingerprint,
      ),
      isTrue,
    );
    expect(
      await security.consumeFreshOutboundPinProof(
        deviceId: deviceId,
        peerFingerprint: peerFingerprint,
        localFingerprint: localFingerprint,
      ),
      isFalse,
    );
  });

  test('an existing device id cannot silently change certificate', () async {
    await security.storePeerCertificateFingerprint(deviceId, peerFingerprint);

    await expectLater(
      security.storePeerCertificateFingerprint(deviceId, otherFingerprint),
      throwsStateError,
    );
    expect(
      await security.getPeerCertificateFingerprint(deviceId),
      peerFingerprint,
    );
  });
}
