import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DataProtectionService {
  static const _keyStorageKey = 'data_protection_key_v1';
  static const encryptedPrefix = 'ssh-mobile-v1:';

  static final DataProtectionService instance = DataProtectionService._();

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final AesGcm _algorithm = AesGcm.with256bits();
  SecretKey? _cachedKey;

  DataProtectionService._();

  Future<String> encryptString(String plaintext) async {
    if (plaintext.isEmpty) return '$encryptedPrefix.';
    final key = await _getOrCreateKey();
    final secretBox = await _algorithm.encryptString(plaintext, secretKey: key);
    final payload = {
      'n': base64Encode(secretBox.nonce),
      'm': base64Encode(secretBox.mac.bytes),
      'c': base64Encode(secretBox.cipherText),
    };
    return '$encryptedPrefix${base64Encode(utf8.encode(jsonEncode(payload)))}';
  }

  Future<String> decryptString(String value) async {
    if (!isEncrypted(value)) return value;
    final body = value.substring(encryptedPrefix.length);
    if (body == '.') return '';

    final decoded = utf8.decode(base64Decode(body));
    final payload = jsonDecode(decoded) as Map<String, dynamic>;
    final key = await _getOrCreateKey();
    final box = SecretBox(
      base64Decode(payload['c'] as String),
      nonce: base64Decode(payload['n'] as String),
      mac: Mac(base64Decode(payload['m'] as String)),
    );
    return _algorithm.decryptString(box, secretKey: key);
  }

  bool isEncrypted(String value) => value.startsWith(encryptedPrefix);

  Future<SecretKey> _getOrCreateKey() async {
    final existing = _cachedKey;
    if (existing != null) return existing;

    final stored = await _secureStorage.read(key: _keyStorageKey);
    if (stored?.isNotEmpty == true) {
      final key = SecretKey(base64Decode(stored!));
      _cachedKey = key;
      return key;
    }

    final key = await _algorithm.newSecretKey();
    final bytes = await key.extractBytes();
    await _secureStorage.write(key: _keyStorageKey, value: base64Encode(bytes));
    _cachedKey = key;
    return key;
  }
}
