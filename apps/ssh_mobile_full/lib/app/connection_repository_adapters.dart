// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:connection_core/connection_core.dart' as connection_core;

import '../services/storage_service.dart';

/// 将新的 Connection Core Repository 与旧 StorageService 连接起来。
///
/// Step 06 仍有多个旧服务直接读取 StorageService，因此这里执行一次性
/// 双向缺失数据同步，并在新 Feature 写入时同步旧存储。等后续 SSH/SFTP
/// 模块完成迁移后，这个桥可以删除，不改变 Feature 的公共契约。
final class AppConnectionRepositoryAdapter
    implements connection_core.ConnectionRepository {
  AppConnectionRepositoryAdapter({
    required connection_core.ConnectionRepository primary,
    required StorageService legacy,
  }) : _primary = primary,
       _legacy = legacy;

  final connection_core.ConnectionRepository _primary;
  final StorageService _legacy;
  Future<void>? _initialization;

  @override
  List<connection_core.ConnectionConfig> get connections =>
      _primary.connections;

  @override
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await Future.wait([_primary.initialize(), _legacy.initialize()]);
    final primaryConnections = await _primary.loadConnections();
    final legacyConnections = await _legacy.loadConnections();
    final primaryIds = primaryConnections.map((item) => item.id).toSet();
    final legacyIds = legacyConnections.map((item) => item.id).toSet();

    // 首次迁移优先保留旧数据，避免升级后用户看到空列表。
    for (final config in legacyConnections) {
      if (!primaryIds.contains(config.id)) {
        await _primary.addConnection(config);
      }
    }

    // 如果新库已由其他入口写入，则补回旧服务仍需要的结构快照。
    for (final config in primaryConnections) {
      if (!legacyIds.contains(config.id)) {
        await _legacy.addConnection(config);
      }
    }
  }

  @override
  Future<List<connection_core.ConnectionConfig>> loadConnections() async {
    await initialize();
    return _primary.loadConnections();
  }

  @override
  Future<void> addConnection(connection_core.ConnectionConfig config) async {
    await initialize();
    await _primary.addConnection(config);
    await _legacy.addConnection(config);
  }

  @override
  Future<void> updateConnection(connection_core.ConnectionConfig config) async {
    await initialize();
    await _primary.updateConnection(config);
    final legacyConfig = _legacy.getConnection(config.id);
    if (legacyConfig == null) {
      await _legacy.addConnection(config);
    } else {
      await _legacy.updateConnection(config);
    }
  }

  @override
  Future<void> deleteConnection(String id) async {
    await initialize();
    await _primary.deleteConnection(id);
    await _legacy.deleteConnection(id);
  }

  @override
  Future<void> deleteConnections(List<String> ids) async {
    await initialize();
    await _primary.deleteConnections(ids);
    await _legacy.deleteConnections(ids);
  }

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    await initialize();
    await _primary.reorderConnections(oldIndex, newIndex);
    await _legacy.reorderConnections(oldIndex, newIndex);
  }

  @override
  connection_core.ConnectionConfig? getConnection(String id) =>
      _primary.getConnection(id);
}

/// 新凭据契约到旧 StorageService 的过渡桥。
///
/// 读取时支持旧数据回退并自动填充新 Secure Storage；写入时同时保持旧
/// SSH/SFTP 实现可读。Feature 本身只看 CredentialRepository，不感知双写。
final class AppConnectionCredentialAdapter
    implements connection_core.CredentialRepository {
  AppConnectionCredentialAdapter({
    required connection_core.CredentialRepository primary,
    required StorageService legacy,
  }) : _primary = primary,
       _legacy = legacy;

  final connection_core.CredentialRepository _primary;
  final StorageService _legacy;

  @override
  Future<String?> getPassword(String connectionId) async {
    final current = await _primary.getPassword(connectionId);
    if (current?.isNotEmpty == true) return current;
    final legacy = await _legacy.getPassword(connectionId);
    if (legacy?.isNotEmpty == true) {
      await _hydrate(connectionId, password: legacy);
    }
    return legacy;
  }

  @override
  Future<String?> getPrivateKey(String connectionId) async {
    final current = await _primary.getPrivateKey(connectionId);
    if (current?.isNotEmpty == true) return current;
    final legacy = await _legacy.getPrivateKey(connectionId);
    if (legacy?.isNotEmpty == true) {
      await _hydrate(connectionId, privateKey: legacy);
    }
    return legacy;
  }

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    await _primary.saveCredentials(
      connectionId: connectionId,
      password: password,
      privateKey: privateKey,
    );
    final config = _legacy.getConnection(connectionId);
    if (config == null) return;
    await _legacy.updateConnection(
      _withCredentials(config, password: password, privateKey: privateKey),
    );
  }

  @override
  Future<void> deleteCredentials(String connectionId) async {
    await _primary.deleteCredentials(connectionId);
    final config = _legacy.getConnection(connectionId);
    if (config != null) {
      await _legacy.updateConnection(_withoutCredentials(config));
    }
  }

  Future<void> _hydrate(
    String connectionId, {
    String? password,
    String? privateKey,
  }) async {
    final otherPassword = await _primary.getPassword(connectionId);
    final otherPrivateKey = await _primary.getPrivateKey(connectionId);
    await _primary.saveCredentials(
      connectionId: connectionId,
      password: password ?? otherPassword,
      privateKey: privateKey ?? otherPrivateKey,
    );
  }

  connection_core.ConnectionConfig _withCredentials(
    connection_core.ConnectionConfig config, {
    required String? password,
    required String? privateKey,
  }) {
    final clean = _withoutCredentials(config);
    clean.password = password;
    clean.privateKey = privateKey;
    return clean;
  }

  connection_core.ConnectionConfig _withoutCredentials(
    connection_core.ConnectionConfig config,
  ) => connection_core.ConnectionConfig.fromJson(config.toJson());
}

/// Host Key 元数据的双写适配器，保持旧 SSH 客户端和新数据库一致。
final class AppConnectionHostKeyAdapter
    implements connection_core.HostKeyRepository {
  AppConnectionHostKeyAdapter({
    required connection_core.HostKeyRepository primary,
    required StorageService legacy,
  }) : _primary = primary,
       _legacy = legacy;

  final connection_core.HostKeyRepository _primary;
  final StorageService _legacy;

  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {
    await _primary.trustHostKey(
      connectionId,
      algorithm: algorithm,
      fingerprint: fingerprint,
      trustedAt: trustedAt,
    );
    await _legacy.trustHostKey(
      connectionId,
      algorithm: algorithm,
      fingerprint: fingerprint,
      trustedAt: trustedAt,
    );
  }
}
