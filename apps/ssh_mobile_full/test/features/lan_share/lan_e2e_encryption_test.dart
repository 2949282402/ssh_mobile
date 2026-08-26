import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

import 'support/fake_secure_storage.dart';

void main() {
  group('LanSecurityService E2E Encryption Tests', () {
    late LanSecurityService aliceSecurity;
    late LanSecurityService bobSecurity;

    setUp(() {
      aliceSecurity = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List.fromList(List<int>.filled(32, 1)),
        secureStorage: FakeSecureStorage(),
      );
      bobSecurity = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List.fromList(List<int>.filled(32, 2)),
        secureStorage: FakeSecureStorage(),
      );
    });

    test('Key generation and exchange', () async {
      final alicePubBytes = await aliceSecurity.getStaticX25519PublicKeyBytes();
      final bobPubBytes = await bobSecurity.getStaticX25519PublicKeyBytes();

      expect(alicePubBytes.length, equals(32));
      expect(bobPubBytes.length, equals(32));
      expect(alicePubBytes, isNot(equals(bobPubBytes)));
    });

    test('E2E Encrypt and Decrypt text content', () async {
      final bobPubBytes = await bobSecurity.getStaticX25519PublicKeyBytes();

      final originalText = 'Hello Bob, this is Alice with E2E encryption!';
      final plainBytes = utf8.encode(originalText);

      // Alice encrypts for Bob
      final encryptedBlob = await aliceSecurity.encryptE2EFor(
        Uint8List.fromList(plainBytes),
        bobPubBytes,
      );

      // Bob decrypts the blob
      final decryptedBytes = await bobSecurity.decryptE2E(encryptedBlob);
      final decryptedText = utf8.decode(decryptedBytes);

      expect(decryptedText, equals(originalText));
    });

    test('Decryption throws on tampered payload', () async {
      final bobPubBytes = await bobSecurity.getStaticX25519PublicKeyBytes();
      final plainBytes = utf8.encode('Secret Data');

      final encryptedBlob = await aliceSecurity.encryptE2EFor(
        Uint8List.fromList(plainBytes),
        bobPubBytes,
      );

      // Tamper one byte of the ciphertext part (offset after 32B pubkey + 12B nonce)
      encryptedBlob[45] ^= 0xFF;

      expect(
        () => bobSecurity.decryptE2E(encryptedBlob),
        throwsA(isA<Exception>()),
      );
    });
  });
}
