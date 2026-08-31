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

  test(
    'generates a key when storage is empty and preserves encryption errors',
    () async {
      final generatedStorage = _MemorySecureStorage();
      final generated = DataProtectionService.forTesting(
        secureStorage: generatedStorage,
      );

      final encrypted = await generated.encryptString('generated key');
      expect(await generated.decryptString(encrypted), 'generated key');
      expect(generatedStorage.values['data_protection_key_v1'], isNotEmpty);
      expect(generatedStorage.readCalls, 1);

      await generated.encryptBytes(Uint8List.fromList(<int>[1, 2, 3]));
      expect(
        generatedStorage.readCalls,
        1,
        reason: 'the generated key should be reused from the in-memory cache',
      );

      final failingStorage = _MemorySecureStorage(
        readError: StateError('secure storage unavailable'),
      );
      final failing = DataProtectionService.forTesting(
        secureStorage: failingStorage,
      );
      await expectLater(
        failing.encryptString('failure'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        failing.encryptBytes(Uint8List.fromList(<int>[9])),
        throwsA(isA<StateError>()),
      );
    },
  );
}

final class _MemorySecureStorage implements FlutterSecureStorage {
  _MemorySecureStorage({this.readError});

  final Object? readError;
  final Map<String, String> values = <String, String>{};
  var readCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        readCalls++;
        if (readError != null) throw readError!;
        return Future<String?>.value(key == null ? null : values[key]);
      case #write:
        final value = invocation.namedArguments[#value] as String?;
        if (key != null && value != null) values[key] = value;
        return Future<void>.value();
      default:
        throw UnimplementedError('Unexpected secure-storage call: $invocation');
    }
  }
}
