import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('security rejects a non-AppScope X25519 seed', () {
    expect(
      () => LanSecurityService(appOwnedX25519PrivateSeed: Uint8List(31)),
      throwsArgumentError,
    );
  });

  test(
    'changed certificate fingerprint fails closed without overwriting trust',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      );
      addTearDown(store.dispose);

      await _save(security);

      await expectLater(
        security.savePeerTrustRecord(
          deviceId: 'peer-a',
          certificateFingerprint:
              'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
          inboundAccessToken: 'inbound-token',
          outboundAccessToken: 'outbound-token',
          x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
          networkIdentityPublicKey: Uint8List.fromList(
            List<int>.filled(32, 0x22),
          ),
        ),
        throwsStateError,
      );
      expect(
        (await store.read('peer-a'))?.certificateFingerprint,
        _fingerprint,
      );
    },
  );

  test(
    'changed X25519 or Network Identity fails closed without overwriting trust',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      );
      addTearDown(store.dispose);
      await _save(security);

      await expectLater(
        security.savePeerTrustRecord(
          deviceId: 'peer-a',
          certificateFingerprint: _fingerprint,
          inboundAccessToken: 'inbound-token',
          outboundAccessToken: 'outbound-token',
          x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x33)),
          networkIdentityPublicKey: Uint8List.fromList(
            List<int>.filled(32, 0x22),
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        security.savePeerTrustRecord(
          deviceId: 'peer-a',
          certificateFingerprint: _fingerprint,
          inboundAccessToken: 'inbound-token',
          outboundAccessToken: 'outbound-token',
          x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
          networkIdentityPublicKey: Uint8List.fromList(
            List<int>.filled(32, 0x44),
          ),
        ),
        throwsStateError,
      );
      final existing = await store.read('peer-a');
      expect(
        existing?.x25519PublicKey,
        orderedEquals(List<int>.filled(32, 0x11)),
      );
      expect(
        existing?.networkIdentityPublicKey,
        orderedEquals(List<int>.filled(32, 0x22)),
      );
    },
  );
}

const String _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Future<void> _save(LanSecurityService security) => security.savePeerTrustRecord(
  deviceId: 'peer-a',
  certificateFingerprint: _fingerprint,
  inboundAccessToken: 'inbound-token',
  outboundAccessToken: 'outbound-token',
  x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
  networkIdentityPublicKey: Uint8List.fromList(List<int>.filled(32, 0x22)),
);
