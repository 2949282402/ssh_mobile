import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('V2 trust records round-trip all authenticated material atomically', () {
    final record = _record();

    final restored = LanPeerTrustRecord.fromJson(record.toJson());

    expect(restored.deviceId, record.deviceId);
    expect(restored.certificateFingerprint, record.certificateFingerprint);
    expect(restored.inboundAccessToken, record.inboundAccessToken);
    expect(restored.outboundAccessToken, record.outboundAccessToken);
    expect(restored.x25519PublicKey, orderedEquals(record.x25519PublicKey));
    expect(
      restored.networkIdentityPublicKey,
      orderedEquals(record.networkIdentityPublicKey),
    );
    expect(restored.authorization.localDirect, isTrue);
    expect(restored.authorization.relay, isFalse);
    expect(restored.origin, PeerTrustOrigin.localPin);
  });

  test('trust record rejects relay-only and route-less authorization', () {
    expect(
      () => LanPeerTrustRecord(
        deviceId: 'peer-a',
        certificateFingerprint: _fingerprint,
        inboundAccessToken: 'inbound',
        outboundAccessToken: 'outbound',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: false,
          relay: true,
        ),
        createdAt: DateTime.utc(2026, 1, 1),
      ),
      throwsFormatException,
    );

    expect(
      () => LanPeerTrustRecord(
        deviceId: 'peer-a',
        certificateFingerprint: _fingerprint,
        inboundAccessToken: 'inbound',
        outboundAccessToken: 'outbound',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: false,
          relay: false,
        ),
        createdAt: DateTime.utc(2026, 1, 1),
      ),
      throwsFormatException,
    );
  });

  test(
    'first load clears fragmented V1 state and creates one V2 document',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'lan_share_paired_device_ids': jsonEncode(<String>['peer-a']),
        'lan_share_inbound_access_tokens': jsonEncode(<String, String>{
          'peer-a': 'inbound',
        }),
        'lan_share_outbound_access_tokens': jsonEncode(<String, String>{
          'peer-a': 'outbound',
        }),
        'lan_share_trusted_fingerprints': jsonEncode(<String, String>{
          'peer-a': _fingerprint,
        }),
      });
      const storage = FlutterSecureStorage();
      final store = LanPeerTrustStore(secureStorage: storage);
      addTearDown(store.dispose);

      expect(await store.loadAll(), isEmpty);

      final v2 = await storage.read(key: 'lan_share_peer_trust_v2');
      expect(v2, isNotNull);
      final document = jsonDecode(v2!) as Map<String, dynamic>;
      expect(document['schemaVersion'], LanPeerTrustStore.schemaVersion);
      expect(document['records'], isEmpty);
      expect(await storage.read(key: 'lan_share_paired_device_ids'), isNull);
      expect(
        await storage.read(key: 'lan_share_inbound_access_tokens'),
        isNull,
      );
      expect(
        await storage.read(key: 'lan_share_outbound_access_tokens'),
        isNull,
      );
      expect(await storage.read(key: 'lan_share_trusted_fingerprints'), isNull);
    },
  );

  test(
    'saving a peer emits one complete document and relay authorization is durable',
    () async {
      final store = LanPeerTrustStore();
      addTearDown(store.dispose);
      await store.loadAll();

      final firstChange = store.changes.first;
      await store.save(_record());
      final changes = await firstChange;
      expect(changes, hasLength(1));
      expect(changes.single.deviceId, 'peer-a');

      await store.setRelayAuthorization('peer-a', true);
      final authorized = await store.read('peer-a');
      expect(authorized?.authorization.localDirect, isTrue);
      expect(authorized?.authorization.relay, isTrue);

      final storage = const FlutterSecureStorage();
      final raw = await storage.read(key: 'lan_share_peer_trust_v2');
      final document = jsonDecode(raw!) as Map<String, dynamic>;
      final encoded =
          (document['records'] as List<dynamic>).single as Map<String, dynamic>;
      expect(encoded['localDirect'], isTrue);
      expect(encoded['relay'], isTrue);
      expect(encoded['x25519PublicKey'], isA<String>());
      expect(encoded['networkIdentityPublicKey'], isA<String>());
    },
  );

  test(
    'a new trust-store instance restores local direct trust after restart',
    () async {
      final storage = const FlutterSecureStorage();
      final first = LanPeerTrustStore(secureStorage: storage);
      await first.save(_record());
      await first.dispose();

      final second = LanPeerTrustStore(secureStorage: storage);
      addTearDown(second.dispose);
      final restored = await second.read('peer-a');

      expect(restored, isNotNull);
      expect(restored?.authorization.localDirect, isTrue);
      expect(restored?.authorization.relay, isFalse);
      expect(restored?.x25519PublicKey, hasLength(32));
      expect(restored?.networkIdentityPublicKey, hasLength(32));
    },
  );

  test(
    'malformed V2 documents fail closed and are replaced with an empty schema',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'lan_share_peer_trust_v2': jsonEncode(<String, Object>{
          'schemaVersion': 1,
          'records': <Object>[],
        }),
        'lan_share_peer_x25519_keys_v1': 'legacy-secret-bearing-state',
      });
      const storage = FlutterSecureStorage();
      final store = LanPeerTrustStore(secureStorage: storage);
      addTearDown(store.dispose);

      expect(await store.loadAll(), isEmpty);

      final raw = await storage.read(key: 'lan_share_peer_trust_v2');
      final document = jsonDecode(raw!) as Map<String, dynamic>;
      expect(document['schemaVersion'], LanPeerTrustStore.schemaVersion);
      expect(document['records'], isEmpty);
      expect(await storage.read(key: 'lan_share_peer_x25519_keys_v1'), isNull);
    },
  );

  for (final missingField in <String>[
    'certificateFingerprint',
    'inboundAccessToken',
    'outboundAccessToken',
    'x25519PublicKey',
    'networkIdentityPublicKey',
  ]) {
    test('missing $missingField cannot become a trusted peer', () async {
      final encoded = Map<String, Object>.from(_record().toJson())
        ..remove(missingField);
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'lan_share_peer_trust_v2': jsonEncode(<String, Object>{
          'schemaVersion': LanPeerTrustStore.schemaVersion,
          'records': <Object>[encoded],
        }),
      });
      const storage = FlutterSecureStorage();
      final store = LanPeerTrustStore(secureStorage: storage);
      addTearDown(store.dispose);

      expect(await store.loadAll(), isEmpty);
      expect(await store.read('peer-a'), isNull);
    });
  }
}

const String _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

LanPeerTrustRecord _record() => LanPeerTrustRecord(
  deviceId: 'peer-a',
  certificateFingerprint: _fingerprint,
  inboundAccessToken: 'inbound-token',
  outboundAccessToken: 'outbound-token',
  x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
  networkIdentityPublicKey: Uint8List.fromList(List<int>.filled(32, 0x22)),
  origin: PeerTrustOrigin.localPin,
  authorization: const PeerRouteAuthorization(localDirect: true, relay: false),
  createdAt: DateTime.utc(2026, 1, 1),
);
