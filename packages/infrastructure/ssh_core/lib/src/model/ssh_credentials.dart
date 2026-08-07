// SSH 凭据运行时模型。
//
// 凭据只在连接建立所需的短生命周期内存在，不提供 JSON 序列化，避免被
// 日志、缓存或持久化层意外带出。

/// SSH 密码和私钥的短生命周期组合。
final class SshCredentials {
  /// 创建一组运行时凭据。
  const SshCredentials({required this.password, required this.privateKey});

  /// 可选密码。
  final String? password;

  /// 可选 PEM 私钥。
  final String? privateKey;
}
