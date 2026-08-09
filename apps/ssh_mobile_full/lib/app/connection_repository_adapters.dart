import 'package:connection_core/connection_core.dart' as connection_core;

/// Connection Core Repository 的 App Shell 转发层。
///
/// 该层只保留 App 与 Feature 之间的公开契约适配，不再做旧数据库双写或
/// 数据回填。ConnectionDatabase、结构 Repository 和安全凭据 Repository
/// 的生命周期均由 AppRuntime 持有。
final class AppConnectionRepositoryAdapter
    implements connection_core.ConnectionRepository {
  /// 创建不拥有底层 Repository 的转发适配器。
  const AppConnectionRepositoryAdapter({required this.primary});

  /// AppRuntime 创建的唯一 Connection Repository。
  final connection_core.ConnectionRepository primary;

  @override
  List<connection_core.ConnectionConfig> get connections => primary.connections;

  @override
  Future<void> initialize() => primary.initialize();

  @override
  Future<List<connection_core.ConnectionConfig>> loadConnections() =>
      primary.loadConnections();

  @override
  Future<void> addConnection(connection_core.ConnectionConfig config) =>
      primary.addConnection(config);

  @override
  Future<void> updateConnection(connection_core.ConnectionConfig config) =>
      primary.updateConnection(config);

  @override
  Future<void> deleteConnection(String id) => primary.deleteConnection(id);

  @override
  Future<void> deleteConnections(List<String> ids) =>
      primary.deleteConnections(ids);

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) =>
      primary.reorderConnections(oldIndex, newIndex);

  @override
  connection_core.ConnectionConfig? getConnection(String id) =>
      primary.getConnection(id);
}

/// Connection Core Credential Repository 的非拥有型转发适配器。
final class AppConnectionCredentialAdapter
    implements connection_core.CredentialRepository {
  /// 创建凭据转发适配器。
  const AppConnectionCredentialAdapter({required this.primary});

  /// AppRuntime 创建的唯一安全凭据 Repository。
  final connection_core.CredentialRepository primary;

  @override
  Future<String?> getPassword(String connectionId) =>
      primary.getPassword(connectionId);

  @override
  Future<String?> getPrivateKey(String connectionId) =>
      primary.getPrivateKey(connectionId);

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) => primary.saveCredentials(
    connectionId: connectionId,
    password: password,
    privateKey: privateKey,
  );

  @override
  Future<void> deleteCredentials(String connectionId) =>
      primary.deleteCredentials(connectionId);
}

/// Connection Core Host Key Repository 的非拥有型转发适配器。
final class AppConnectionHostKeyAdapter
    implements connection_core.HostKeyRepository {
  /// 创建 Host Key 转发适配器。
  const AppConnectionHostKeyAdapter({required this.primary});

  /// AppRuntime 创建的唯一 Host Key Repository。
  final connection_core.HostKeyRepository primary;

  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) => primary.trustHostKey(
    connectionId,
    algorithm: algorithm,
    fingerprint: fingerprint,
    trustedAt: trustedAt,
  );
}
