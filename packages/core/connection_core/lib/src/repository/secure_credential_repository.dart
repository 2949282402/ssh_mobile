import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_repository.dart';

/// Secure Storage 最小适配契约，便于在不触碰真实 Keychain/KeyStore 的情况下测试。
abstract interface class SecureStorageClient {
  /// 读取一个受保护值。
  Future<String?> read({required String key});

  /// 写入一个受保护值。
  Future<void> write({required String key, required String value});

  /// 删除一个受保护值。
  Future<void> delete({required String key});
}

/// 对 FlutterSecureStorage 的最小适配，统一插件生命周期边界。
final class FlutterSecureStorageClient implements SecureStorageClient {
  /// 使用应用统一的安全存储默认配置。
  FlutterSecureStorageClient({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

/// 将 Connection 密码和私钥绑定到平台 Secure Storage 的 Repository。
///
/// 键名带有模块前缀，避免与旧 StorageService 的 SharedPreferences/Secret
/// 键混用；空值通过 delete 写入路径处理，避免把空字符串误认为有效凭据。
final class SecureCredentialRepository implements CredentialRepository {
  /// 密码键前缀。
  static const passwordKeyPrefix = 'connection.password.';

  /// 私钥键前缀。
  static const privateKeyKeyPrefix = 'connection.private_key.';

  /// 创建一个使用注入安全存储客户端的凭据 Repository。
  SecureCredentialRepository({SecureStorageClient? storage})
    : _storage = storage ?? FlutterSecureStorageClient();

  final SecureStorageClient _storage;

  @override
  Future<String?> getPassword(String connectionId) =>
      _storage.read(key: _passwordKey(connectionId));

  @override
  Future<String?> getPrivateKey(String connectionId) =>
      _storage.read(key: _privateKeyKey(connectionId));

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    await _writeOrDelete(_passwordKey(connectionId), password);
    await _writeOrDelete(_privateKeyKey(connectionId), privateKey);
  }

  @override
  Future<void> deleteCredentials(String connectionId) async {
    await _storage.delete(key: _passwordKey(connectionId));
    await _storage.delete(key: _privateKeyKey(connectionId));
  }

  Future<void> _writeOrDelete(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  String _passwordKey(String connectionId) =>
      '$passwordKeyPrefix${_validateId(connectionId)}';

  String _privateKeyKey(String connectionId) =>
      '$privateKeyKeyPrefix${_validateId(connectionId)}';

  String _validateId(String connectionId) {
    final value = connectionId.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(connectionId, 'connectionId');
    }
    return value;
  }
}
