import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('V2 trust pins the certificate and both static identities', () async {
    final store = LanPeerTrustStore();
    final security = LanSecurityService(
      appOwnedX25519PrivateSeed: Uint8List(32),
      peerTrustStore: store,
    );
    addTearDown(store.dispose);

    await _save(security);
    final record = await store.read('peer-device');

    expect(record?.certificateFingerprint, _fingerprint);
    expect(record?.x25519PublicKey, orderedEquals(_x25519));
    expect(record?.networkIdentityPublicKey, orderedEquals(_networkIdentity));
    expect(record?.authorization.localDirect, isTrue);
    expect(record?.authorization.relay, isFalse);
  });

  test('V2 identity changes fail closed without overwriting trust', () async {
    final store = LanPeerTrustStore();
    final security = LanSecurityService(
      appOwnedX25519PrivateSeed: Uint8List(32),
      peerTrustStore: store,
    );
    addTearDown(store.dispose);
    await _save(security);

    await expectLater(
      security.savePeerTrustRecord(
        deviceId: 'peer-device',
        certificateFingerprint: _otherFingerprint,
        inboundAccessToken: _inbound,
        outboundAccessToken: _outbound,
        x25519PublicKey: _x25519,
        networkIdentityPublicKey: _networkIdentity,
      ),
      throwsStateError,
    );
    await expectLater(
      security.savePeerTrustRecord(
        deviceId: 'peer-device',
        certificateFingerprint: _fingerprint,
        inboundAccessToken: _inbound,
        outboundAccessToken: _outbound,
        x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x33)),
        networkIdentityPublicKey: _networkIdentity,
      ),
      throwsStateError,
    );
    await expectLater(
      security.savePeerTrustRecord(
        deviceId: 'peer-device',
        certificateFingerprint: _fingerprint,
        inboundAccessToken: _inbound,
        outboundAccessToken: _outbound,
        x25519PublicKey: _x25519,
        networkIdentityPublicKey: Uint8List.fromList(
          List<int>.filled(32, 0x44),
        ),
      ),
      throwsStateError,
    );

    final record = await store.read('peer-device');
    expect(record?.certificateFingerprint, _fingerprint);
    expect(record?.x25519PublicKey, orderedEquals(_x25519));
    expect(record?.networkIdentityPublicKey, orderedEquals(_networkIdentity));
  });
}

const String _fingerprint =
    '1111111111111111111111111111111111111111111111111111111111111111';
const String _otherFingerprint =
    '2222222222222222222222222222222222222222222222222222222222222222';
const String _inbound = 'inbound-access-token';
const String _outbound = 'outbound-access-token';
final Uint8List _x25519 = Uint8List.fromList(List<int>.filled(32, 0x11));
final Uint8List _networkIdentity = Uint8List.fromList(
  List<int>.filled(32, 0x22),
);

Future<void> _save(LanSecurityService security) => security.savePeerTrustRecord(
  deviceId: 'peer-device',
  certificateFingerprint: _fingerprint,
  inboundAccessToken: _inbound,
  outboundAccessToken: _outbound,
  x25519PublicKey: _x25519,
  networkIdentityPublicKey: _networkIdentity,
);
