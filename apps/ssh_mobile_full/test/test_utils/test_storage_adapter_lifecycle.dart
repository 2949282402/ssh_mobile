part of 'test_storage_adapter.dart';

/// Owns shutdown and test-owned child resource lifecycles.
mixin _TestStorageAdapterLifecycle on _TestStorageAdapterBase {
  Future<void> markPowerGuideSeen() async {
    // Power Guide 的生产 Owner 已迁移到 AppSettings；测试夹具只保留
    // 旧查询面，避免把该状态重新写回 AI 数据库。
    await _delegate.init();
  }

  /// 关闭 Repository、SharedPreferences 写入队列和测试专用 AI 数据库。
  Future<void> shutdown() async {
    for (final service in List<TestRagService>.of(_ownedRagServices)) {
      await service.close();
    }
    _ownedRagServices.clear();
    await _delegate.shutdown();
    for (final database in _ownedAiDatabases) {
      await database.dispose();
    }
    _ownedAiDatabases.clear();
  }

  void _registerRagService(TestRagService service) {
    _ownedRagServices.add(service);
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
