/// 连接凭据的公共契约。
///
/// 凭据不属于 Connection Drift 表，也不应通过 ConnectionConfig 的 JSON、
/// 日志或备份流转；实现必须使用平台安全存储或等价的受保护后端。
abstract interface class CredentialRepository {
  /// 读取指定连接的密码。
  Future<String?> getPassword(String connectionId);

  /// 读取指定连接的私钥。
  Future<String?> getPrivateKey(String connectionId);

  /// 保存或删除指定连接的密码与私钥。
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  });

  /// 删除指定连接的全部凭据。
  Future<void> deleteCredentials(String connectionId);
}
