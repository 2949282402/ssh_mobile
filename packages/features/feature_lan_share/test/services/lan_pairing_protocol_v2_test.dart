import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  test('pairing protocol is V2 and binds both static peer identities', () {
    expect(LanPairingCrypto.protocolVersion, 2);

    final senderX25519 = Uint8List.fromList(List<int>.filled(32, 1));
    final senderNetworkIdentity = Uint8List.fromList(List<int>.filled(32, 2));
    final serverX25519 = Uint8List.fromList(List<int>.filled(32, 3));
    final serverNetworkIdentity = Uint8List.fromList(List<int>.filled(32, 4));
    final tokenHash = LanPairingCrypto.accessTokenHash('one-shot-token');
    final context = LanPairingCrypto.clientContext(
      senderDeviceId: 'sender',
      targetDeviceId: 'target',
      nonce: 'nonce-0123456789',
      alias: 'Sender',
      os: 'test',
      port: 53317,
      isInitiator: true,
      senderCertFingerprint: _fingerprint,
      senderX25519PublicKey: senderX25519,
      senderNetworkIdentityPublicKey: senderNetworkIdentity,
      senderInboundAccessTokenHash: tokenHash,
    );
    final session = LanPairingCrypto.sessionAssociatedData(
      clientContext: context,
      handshakeId: 'handshake-0123456789',
      slot: 0,
      salt: Uint8List(32),
      clientPublicValue: Uint8List(384),
      serverPublicValue: Uint8List(384),
      serverCertFingerprint: _fingerprint,
      serverX25519PublicKey: serverX25519,
      serverNetworkIdentityPublicKey: serverNetworkIdentity,
    );

    expect(context, contains('sender'));
    expect(context, contains(tokenHash));
    expect(session, contains('handshake-0123456789'));
    expect(session, contains(_fingerprint));

    final changedSenderKey = LanPairingCrypto.clientContext(
      senderDeviceId: 'sender',
      targetDeviceId: 'target',
      nonce: 'nonce-0123456789',
      alias: 'Sender',
      os: 'test',
      port: 53317,
      isInitiator: true,
      senderCertFingerprint: _fingerprint,
      senderX25519PublicKey: Uint8List.fromList(List<int>.filled(32, 9)),
      senderNetworkIdentityPublicKey: senderNetworkIdentity,
      senderInboundAccessTokenHash: tokenHash,
    );
    expect(changedSenderKey, isNot(context));

    final changedServerKey = LanPairingCrypto.sessionAssociatedData(
      clientContext: context,
      handshakeId: 'handshake-0123456789',
      slot: 0,
      salt: Uint8List(32),
      clientPublicValue: Uint8List(384),
      serverPublicValue: Uint8List(384),
      serverCertFingerprint: _fingerprint,
      serverX25519PublicKey: Uint8List.fromList(List<int>.filled(32, 8)),
      serverNetworkIdentityPublicKey: serverNetworkIdentity,
    );
    expect(changedServerKey, isNot(session));
  });

  test('access token hash is bound and compared without persistence', () {
    final hash = LanPairingCrypto.accessTokenHash('one-shot-token');
    expect(
      LanPairingCrypto.verifyAccessTokenHash('one-shot-token', hash),
      isTrue,
    );
    expect(
      LanPairingCrypto.verifyAccessTokenHash('wrong-token', hash),
      isFalse,
    );
    expect(
      LanPairingCrypto.verifyAccessTokenHash(
        'one-shot-token',
        hash.toUpperCase(),
      ),
      isFalse,
    );
  });

  test('static key decoding rejects malformed or non-32-byte values', () {
    final encoded = base64UrlEncode(Uint8List(32));
    expect(
      LanPairingCrypto.decodePublicKey(encoded, 'test key'),
      hasLength(32),
    );
    expect(
      () => LanPairingCrypto.decodePublicKey('', 'test key'),
      throwsFormatException,
    );
    expect(
      () => LanPairingCrypto.decodePublicKey(
        base64UrlEncode(Uint8List(31)),
        'test key',
      ),
      throwsFormatException,
    );
  });
}

const String _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
