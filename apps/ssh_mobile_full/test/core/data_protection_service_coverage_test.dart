import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/core/services/data_protection_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // A valid pre-existing key exercises the secure-storage recovery path while
    // keeping the fixture deterministic and free of real credentials.
    FlutterSecureStorage.setMockInitialValues({
      'data_protection_key_v1': base64Encode(List<int>.filled(32, 7)),
    });
  });

  test('encrypts and decrypts strings, including the empty sentinel', () async {
    final service = DataProtectionService.instance;
    expect(await service.encryptString(''), 'ssh-mobile-v1:.');
    expect(await service.decryptString('ssh-mobile-v1:.'), isEmpty);
    expect(await service.decryptString('legacy plaintext'), 'legacy plaintext');

    final encrypted = await service.encryptString('hello telemetry');
    expect(service.isEncrypted(encrypted), isTrue);
    expect(encrypted, startsWith('ssh-mobile-v1:'));
    expect(await service.decryptString(encrypted), 'hello telemetry');
    expect(service.isEncrypted('ssh-mobile-bin-v1:.'), isFalse);
  });

  test(
    'encrypts and decrypts bytes and recognizes malformed ciphertext',
    () async {
      final service = DataProtectionService.instance;
      final empty = await service.encryptBytes(Uint8List(0));
      expect(utf8.decode(empty), 'ssh-mobile-bin-v1:.');
      expect(await service.decryptBytes(empty), isEmpty);

      final input = Uint8List.fromList(<int>[0, 1, 2, 250, 255]);
      final encrypted = await service.encryptBytes(input);
      expect(service.isEncryptedBytes(encrypted), isTrue);
      expect(await service.decryptBytes(encrypted), orderedEquals(input));
      expect(service.isEncryptedBytes(Uint8List(0)), isFalse);
      expect(
        service.isEncryptedBytes(
          Uint8List.fromList(utf8.encode('ssh-mobile-bin-v2:')),
        ),
        isFalse,
      );

      await expectLater(
        service.decryptString('ssh-mobile-v1:not-base64'),
        throwsA(isA<Object>()),
      );
      await expectLater(
        service.decryptBytes(
          Uint8List.fromList(utf8.encode('ssh-mobile-bin-v1:not-base64')),
        ),
        throwsA(isA<Object>()),
      );
    },
  );
}
