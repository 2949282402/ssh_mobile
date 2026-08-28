part of 'test_storage_adapter.dart';

/// Owns connection and credential facade operations.
mixin _TestStorageAdapterConnections on _TestStorageAdapterBase {
  Future<void> init() => _delegate.init();
  Future<void> initialize() => _delegate.initialize();

  Future<List<ConnectionConfig>> loadConnections() async {
    await init();
    return connections;
  }

  Future<void> addConnection(ConnectionConfig config) =>
      _delegate.addConnection(config);

  Future<void> updateConnection(ConnectionConfig config) =>
      _delegate.updateConnection(config);

  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) => _delegate.trustHostKey(
    connectionId,
    algorithm: algorithm,
    fingerprint: fingerprint,
    trustedAt: trustedAt,
  );

  Future<void> deleteConnection(String id) => _delegate.deleteConnection(id);

  Future<void> deleteConnections(Iterable<String> ids) =>
      _delegate.deleteConnections(ids);

  /// 测试专用的目标绑定 CAS 辅助；生产 CAS 通过 Core Repository 的显式
  /// 读写组合完成，夹具保留该方法以覆盖审批目标不应被旧快照覆盖的行为。
  Future<bool> updateConnectionIfMatches(
    ConnectionTargetBinding binding,
    ConnectionConfig next,
  ) async {
    final current = getConnection(binding.id);
    if (current == null || !binding.matches(current)) return false;
    await updateConnection(next);
    return true;
  }

  /// 测试专用的条件删除辅助。
  Future<bool> deleteConnectionIfMatches(
    ConnectionTargetBinding binding,
  ) async {
    final current = getConnection(binding.id);
    if (current == null || !binding.matches(current)) return false;
    await deleteConnection(binding.id);
    return true;
  }

  /// 测试专用的完整快照 CAS 辅助，避免回归已删除的统一存储 API。
  Future<bool> updateConnectionFromSnapshotIfUnchanged({
    required ConnectionConfig expected,
    required ConnectionConfig next,
  }) async {
    final current = getConnection(expected.id);
    if (current == null ||
        current.toJson().toString() != expected.toJson().toString()) {
      return false;
    }
    await updateConnection(next);
    return true;
  }

  Future<void> reorderConnections(int oldIndex, int newIndex) =>
      _delegate.reorderConnections(oldIndex, newIndex);

  Future<String?> getPassword(String id) => _delegate.getPassword(id);
  Future<String?> getPrivateKey(String id) => _delegate.getPrivateKey(id);

  /// 捕获旧 App Shell 测试所使用的目标绑定；运行时仍由 Core Port 校验。
  Map<String, ConnectionTargetBinding> captureConnectionTargetBindings(
    Iterable<String> ids,
  ) => {
    for (final id in ids)
      if (getConnection(id) != null)
        id: ConnectionTargetBinding.fromConfig(getConnection(id)!),
  };

  Future<ConnectionRuntimeTarget?> resolveConnectionTarget(
    ConnectionTargetBinding binding,
  ) => RemoteTargetScope.resolveBinding(
    binding,
    connectionRepository: connectionRepository,
    credentialRepository: credentialRepository,
  );
}
