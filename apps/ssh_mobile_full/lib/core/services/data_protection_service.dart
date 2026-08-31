import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../services/app_log_service.dart';

/// AES-256-GCM 加密/解密层，用于保护持久化到 SharedPreferences 的敏感数据。
///
/// 架构：密钥生成 → 存入平台 Keychain → 内存缓存 → 加解密。
/// 首次运行时自动生成 256 位密钥并存入 FlutterSecureStorage，
/// 后续从内存缓存读取（避免频繁访问 Keychain）。
///
/// 加密输出格式：`ssh-mobile-v1:<base64(json({n:nonce, m:mac, c:ciphertext}))>`
/// 通过前缀判断是否已加密，兼容历史明文数据。
class DataProtectionService {
  // FlutterSecureStorage 中存储 AES 密钥的键名
  static const _keyStorageKey = 'data_protection_key_v1';
  // 加密数据的前缀标识，用于 isEncrypted 检测
  static const encryptedPrefix = 'ssh-mobile-v1:';
  static const encryptedBytesPrefix = 'ssh-mobile-bin-v1:';
  static final List<int> _encryptedBytesPrefixBytes = utf8.encode(
    encryptedBytesPrefix,
  );

  static final DataProtectionService instance = DataProtectionService._();

  // macOS Data Protection Keychain 需要额外的签名授权，否则返回 -34018 错误
  // 因此显式关闭 usesDataProtectionKeychain
  final FlutterSecureStorage _secureStorage;
  final AesGcm _algorithm;
  SecretKey? _cachedKey; // 内存缓存，避免高频 Keychain 读取

  DataProtectionService._({
    FlutterSecureStorage? secureStorage,
    AesGcm? algorithm,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _algorithm = algorithm ?? AesGcm.with256bits();

  @visibleForTesting
  DataProtectionService.forTesting({
    FlutterSecureStorage? secureStorage,
    AesGcm? algorithm,
  }) : this._(secureStorage: secureStorage, algorithm: algorithm);

  /// 加密明文字符串，返回带前缀的密文。
  /// 空字符串直接返回特化格式 '$encryptedPrefix.' 以保持判据一致性。
  Future<String> encryptString(String plaintext) async {
    if (plaintext.isEmpty) return '$encryptedPrefix.';
    try {
      final key = await _getOrCreateKey();
      final secretBox = await _algorithm.encryptString(
        plaintext,
        secretKey: key,
      );
      final payload = {
        'n': base64Encode(secretBox.nonce), // 随机 nonce（每次加密不同）
        'm': base64Encode(secretBox.mac.bytes), // 认证标签，防篡改
        'c': base64Encode(secretBox.cipherText), // 密文
      };
      return '$encryptedPrefix${base64Encode(utf8.encode(jsonEncode(payload)))}';
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to encrypt string',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 解密密文。如果输入不以 encryptedPrefix 开头，视为未加密直接返回。
  Future<String> decryptString(String value) async {
    if (!isEncrypted(value)) return value;
    final body = value.substring(encryptedPrefix.length);
    if (body == '.') return '';

    try {
      final decoded = utf8.decode(base64Decode(body));
      final payload = jsonDecode(decoded) as Map<String, dynamic>;
      final key = await _getOrCreateKey();
      // 重建 SecretBox（nonce + ciphertext + mac）
      final box = SecretBox(
        base64Decode(payload['c'] as String),
        nonce: base64Decode(payload['n'] as String),
        mac: Mac(base64Decode(payload['m'] as String)),
      );
      return await _algorithm.decryptString(box, secretKey: key);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to decrypt string',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 判断字符串是否已加密（以 'ssh-mobile-v1:' 开头）
  bool isEncrypted(String value) => value.startsWith(encryptedPrefix);

  Future<Uint8List> encryptBytes(Uint8List bytes) async {
    if (bytes.isEmpty) {
      return Uint8List.fromList(utf8.encode('$encryptedBytesPrefix.'));
    }
    try {
      final key = await _getOrCreateKey();
      final secretBox = await _algorithm.encrypt(bytes, secretKey: key);
      final payload = {
        'n': base64Encode(secretBox.nonce),
        'm': base64Encode(secretBox.mac.bytes),
        'c': base64Encode(secretBox.cipherText),
      };
      final encoded =
          '$encryptedBytesPrefix${base64Encode(utf8.encode(jsonEncode(payload)))}';
      return Uint8List.fromList(utf8.encode(encoded));
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to encrypt bytes',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<Uint8List> decryptBytes(Uint8List bytes) async {
    if (!isEncryptedBytes(bytes)) return bytes;
    final text = utf8.decode(bytes);
    final body = text.substring(encryptedBytesPrefix.length);
    if (body == '.') return Uint8List(0);

    try {
      final decoded = utf8.decode(base64Decode(body));
      final payload = jsonDecode(decoded) as Map<String, dynamic>;
      final key = await _getOrCreateKey();
      final box = SecretBox(
        base64Decode(payload['c'] as String),
        nonce: base64Decode(payload['n'] as String),
        mac: Mac(base64Decode(payload['m'] as String)),
      );
      final plaintext = await _algorithm.decrypt(box, secretKey: key);
      return Uint8List.fromList(plaintext);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to decrypt bytes',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  bool isEncryptedBytes(Uint8List bytes) {
    if (bytes.length < _encryptedBytesPrefixBytes.length) return false;
    for (var i = 0; i < _encryptedBytesPrefixBytes.length; i++) {
      if (bytes[i] != _encryptedBytesPrefixBytes[i]) return false;
    }
    return true;
  }

  /// 获取或创建 AES-256 密钥。
  /// 优先从内存缓存 _cachedKey 读，其次读 Keychain，
  /// 最后生成新密钥并存入 Keychain。
  Future<SecretKey> _getOrCreateKey() async {
    final existing = _cachedKey;
    if (existing != null) return existing;

    try {
      final stored = await _secureStorage.read(key: _keyStorageKey);
      if (stored?.isNotEmpty == true) {
        final key = SecretKey(base64Decode(stored!));
        _cachedKey = key;
        return key;
      }

      final key = await _algorithm.newSecretKey();
      final bytes = await key.extractBytes();
      await _secureStorage.write(
        key: _keyStorageKey,
        value: base64Encode(bytes),
      );
      _cachedKey = key;
      return key;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to read or generate data protection key from secure storage',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
