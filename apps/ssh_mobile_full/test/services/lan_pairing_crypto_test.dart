import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  const correctPin = '123456';
  const wrongPin = '654321';
  const serverFingerprint =
      '2222222222222222222222222222222222222222222222222222222222222222';

  String associatedData({
    required LanPairingEphemeralKeyPair client,
    required LanPairingEphemeralKeyPair server,
    required String clientContext,
    String handshakeId = 'handshake-id-with-enough-entropy',
  }) => LanPairingCrypto.sessionAssociatedData(
    clientContext: clientContext,
    handshakeId: handshakeId,
    slot: client.slot,
    salt: client.salt,
    clientPublicValue: client.publicValue,
    serverPublicValue: server.publicValue,
    serverCertFingerprint: serverFingerprint,
    serverX25519PublicKey: _key(0x33),
    serverNetworkIdentityPublicKey: _key(0x44),
  );

  test('SRP peers derive the same session and confirmation keys', () {
    final context = _clientContext();
    final client = LanPairingCrypto.generateClientKeyPair(
      pin: correctPin,
      clientContext: context,
      slot: 0,
    );
    final server = LanPairingCrypto.generateServerKeyPair(
      pin: correctPin,
      clientContext: context,
      slot: 0,
      clientPublicValue: client.publicValue,
    );
    final aad = associatedData(
      client: client,
      server: server,
      clientContext: context,
    );
    final clientSecrets = LanPairingCrypto.deriveSessionSecrets(
      localKeyPair: client,
      remotePublicValue: server.publicValue,
      associatedData: aad,
    );
    final serverSecrets = LanPairingCrypto.deriveSessionSecrets(
      localKeyPair: server,
      remotePublicValue: client.publicValue,
      associatedData: aad,
    );

    expect(clientSecrets.sessionKey, serverSecrets.sessionKey);
    expect(
      LanPairingCrypto.verifyServerProof(
        clientSecrets,
        LanPairingCrypto.createServerProof(serverSecrets),
      ),
      isTrue,
    );
    expect(
      LanPairingCrypto.verifyClientProof(
        serverSecrets,
        LanPairingCrypto.createClientProof(clientSecrets),
      ),
      isTrue,
    );
  });

  test('a wrong PIN cannot verify either confirmation proof', () {
    final context = _clientContext();
    final client = LanPairingCrypto.generateClientKeyPair(
      pin: wrongPin,
      clientContext: context,
      slot: 0,
    );
    final server = LanPairingCrypto.generateServerKeyPair(
      pin: correctPin,
      clientContext: context,
      slot: 0,
      clientPublicValue: client.publicValue,
    );
    final aad = associatedData(
      client: client,
      server: server,
      clientContext: context,
    );
    final clientSecrets = LanPairingCrypto.deriveSessionSecrets(
      localKeyPair: client,
      remotePublicValue: server.publicValue,
      associatedData: aad,
    );
    final serverSecrets = LanPairingCrypto.deriveSessionSecrets(
      localKeyPair: server,
      remotePublicValue: client.publicValue,
      associatedData: aad,
    );

    expect(
      LanPairingCrypto.verifyServerProof(
        clientSecrets,
        LanPairingCrypto.createServerProof(serverSecrets),
      ),
      isFalse,
    );
    expect(
      LanPairingCrypto.verifyClientProof(
        serverSecrets,
        LanPairingCrypto.createClientProof(clientSecrets),
      ),
      isFalse,
    );
  });

  test('rotating PIN slots use independent salts and public values', () {
    final context = _clientContext();
    final first = LanPairingCrypto.generateClientKeyPair(
      pin: correctPin,
      clientContext: context,
      slot: 0,
    );
    final second = LanPairingCrypto.generateClientKeyPair(
      pin: correctPin,
      clientContext: context,
      slot: 1,
    );

    expect(first.salt, isNot(equals(second.salt)));
    expect(first.publicValue, isNot(equals(second.publicValue)));
    expect(
      LanPairingCrypto.isValidPublicValueForTesting(first.publicValue),
      isTrue,
    );
    expect(
      LanPairingCrypto.isValidPublicValueForTesting(Uint8List(384)),
      isFalse,
    );
    expect(
      LanPairingCrypto.isValidPublicValueForTesting(
        Uint8List.fromList(List<int>.filled(384, 0xff)),
      ),
      isFalse,
    );
  });

  test('credential encryption binds associated data', () async {
    final sessionKey = Uint8List.fromList(
      List<int>.generate(32, (index) => index + 1),
    );
    const associatedData = 'bound-handshake-context';
    final encrypted = await LanPairingCrypto.encryptCredential(
      const {'accessToken': 'token', 'validForMs': 15000},
      sessionKey,
      associatedData: associatedData,
    );
    final decoded = await LanPairingCrypto.decryptCredential(
      encrypted,
      sessionKey,
      associatedData: associatedData,
    );
    expect(decoded['accessToken'], 'token');
    await expectLater(
      LanPairingCrypto.decryptCredential(
        encrypted,
        sessionKey,
        associatedData: 'different-context',
      ),
      throwsFormatException,
    );
  });
}

String _clientContext() => LanPairingCrypto.clientContext(
  senderDeviceId: 'client-device',
  targetDeviceId: 'server-device',
  nonce: 'nonce-with-enough-entropy',
  alias: 'Client Device',
  os: 'test',
  port: 53317,
  isInitiator: true,
  senderCertFingerprint:
      '1111111111111111111111111111111111111111111111111111111111111111',
  senderX25519PublicKey: _key(0x11),
  senderNetworkIdentityPublicKey: _key(0x22),
  senderInboundAccessTokenHash:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

Uint8List _key(int value) => Uint8List.fromList(List<int>.filled(32, value));
