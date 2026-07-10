part of '../storage_service.dart';

extension ConnectionOps on StorageService {
  Future<void> _loadConnections() async {
    final jsonStr = await _readProtectedPref(StorageService._connectionsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      _connections = [];
      _refreshConnectionsView();
      return;
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      _connections = list
          .map(
            (item) => ConnectionConfig.fromJson(item as Map<String, dynamic>),
          )
          .toList();
      _refreshConnectionsView();
    } catch (e) {
      AppLogService.instance.error('Failed to load SSH connections', error: e);
      _connections = [];
      _refreshConnectionsView();
    }
  }

  Future<void> _saveConnections() async {
    if (!_initialized || _prefs == null) return;
    final jsonStr = jsonEncode(
      _connections.map((item) => item.toJson()).toList(),
    );
    await _writeProtectedPref(StorageService._connectionsKey, jsonStr);
  }

  Future<void> addConnection(ConnectionConfig config) async {
    _ensureInitialized();

    final exists = _connections.any((item) => item.id == config.id);
    if (exists) {
      throw StateError('Connection id already exists: ${config.id}');
    }

    _connections.add(config);
    _refreshConnectionsView();
    await _saveSecrets(config);
    await _saveConnections();
    notifyStorageListeners();
  }

  Future<void> updateConnection(ConnectionConfig config) async {
    _ensureInitialized();

    final index = _connections.indexWhere((item) => item.id == config.id);
    if (index == -1) {
      throw StateError('Connection does not exist: ${config.id}');
    }

    _connections[index] = config;
    _refreshConnectionsView();
    await _saveSecrets(config);
    await _saveConnections();
    if (config.launchMode != TerminalLaunchMode.tmux) {
      await removeRestorableTmuxSessionsForConnection(config.id);
    }
    notifyStorageListeners();
  }

  Future<void> deleteConnection(String id) async {
    if (!_initialized) return;

    _connections.removeWhere((item) => item.id == id);
    _refreshConnectionsView();
    _clearSecretCacheForConnection(id);
    await _deleteSecure('pwd_$id');
    await _deleteSecure('key_$id');
    await removeRestorableTmuxSessionsForConnection(id);
    await _saveConnections();
    notifyStorageListeners();
  }

  Future<void> deleteConnections(List<String> ids) async {
    if (!_initialized) return;
    for (final id in ids) {
      _connections.removeWhere((item) => item.id == id);
      _clearSecretCacheForConnection(id);
      await _deleteSecure('pwd_$id');
      await _deleteSecure('key_$id');
      await removeRestorableTmuxSessionsForConnection(id);
    }
    _refreshConnectionsView();
    await _saveConnections();
    notifyStorageListeners();
  }

  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    if (!_initialized) return;
    final item = _connections.removeAt(oldIndex);
    _connections.insert(newIndex, item);
    _refreshConnectionsView();
    await _saveConnections();
    notifyStorageListeners();
  }

  void _refreshConnectionsView() {
    _connectionsView = List.unmodifiable(_connections);
  }

  ConnectionConfig? getConnection(String id) {
    try {
      return _connections.firstWhere((item) => item.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<String?> getPassword(String id) async {
    if (!_initialized) return null;
    return _readSecretWithCache(_cacheKeyPassword(id));
  }

  Future<String?> getPrivateKey(String id) async {
    if (!_initialized) return null;
    return _readSecretWithCache(_cacheKeyPrivateKey(id));
  }

  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {
    if (!_initialized) return;
    final index = _connections.indexWhere((item) => item.id == connectionId);
    if (index == -1 || fingerprint?.isNotEmpty != true) return;
    final config = _connections[index];
    config.hostKeyAlgorithm = algorithm;
    config.hostKeyFingerprint = fingerprint;
    config.hostKeyTrustedAt = trustedAt ?? DateTime.now().toUtc();
    config.updatedAt = DateTime.now();
    _refreshConnectionsView();
    await _saveConnections();
    notifyStorageListeners();
  }

  String _cacheKeyPassword(String connectionId) =>
      '${StorageService._passwordSecretKeyPrefix}$connectionId';

  String _cacheKeyPrivateKey(String connectionId) =>
      '${StorageService._privateKeySecretKeyPrefix}$connectionId';

  void _cacheConnectionSecretsFromConfig(ConnectionConfig config) {
    if (!_secretCacheEnabled) return;
    _secretCache[_cacheKeyPassword(config.id)] = _MemorySecret(
      value: config.password,
      loadedAt: DateTime.now(),
    );
    _secretCache[_cacheKeyPrivateKey(config.id)] = _MemorySecret(
      value: config.privateKey,
      loadedAt: DateTime.now(),
    );
  }

  void _clearSecretCacheForConnection(String connectionId) {
    _secretCache.remove(_cacheKeyPassword(connectionId));
    _secretCache.remove(_cacheKeyPrivateKey(connectionId));
  }

  Future<String?> _readSecretWithCache(String key) async {
    if (!_secretCacheEnabled) return _readSecure(key);
    final cached = _readCachedSecretEntry(key);
    if (cached != null) {
      return cached.value;
    }
    final value = await _readSecure(key);
    _secretCache[key] = _MemorySecret(value: value, loadedAt: DateTime.now());
    return value;
  }

  Future<void> _saveSecrets(ConnectionConfig config) async {
    _cacheConnectionSecretsFromConfig(config);
    final passwordKey = _cacheKeyPassword(config.id);
    final privateKeyKey = _cacheKeyPrivateKey(config.id);
    if (config.password != null && config.password!.isNotEmpty) {
      await _writeSecure(passwordKey, config.password!);
    } else {
      await _deleteSecure(passwordKey);
    }

    if (config.privateKey != null && config.privateKey!.isNotEmpty) {
      await _writeSecure(privateKeyKey, config.privateKey!);
    } else {
      await _deleteSecure(privateKeyKey);
    }
  }
}
