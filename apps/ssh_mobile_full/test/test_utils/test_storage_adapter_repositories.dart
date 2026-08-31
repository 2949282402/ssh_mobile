part of 'test_storage_adapter.dart';

final class _TestConnectionRepository implements ConnectionRepository {
  final List<ConnectionConfig> _items = [];

  @override
  List<ConnectionConfig> get connections => List.unmodifiable(_items);

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() async {
    return connections;
  }

  @override
  Future<void> addConnection(ConnectionConfig config) async {
    if (_items.any((item) => item.id == config.id)) {
      throw StateError('Connection already exists: ${config.id}');
    }
    _items.add(config.copyWith());
  }

  @override
  Future<void> updateConnection(ConnectionConfig config) async {
    final index = _items.indexWhere((item) => item.id == config.id);
    if (index < 0) throw StateError('Connection not found: ${config.id}');
    _items[index] = config.copyWith();
  }

  @override
  Future<void> deleteConnection(String id) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) throw StateError('Connection not found: $id');
    _items.removeAt(index);
  }

  @override
  Future<void> deleteConnections(List<String> ids) async {
    for (final id in ids) {
      await deleteConnection(id);
    }
  }

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _items.length) {
      throw RangeError.index(oldIndex, _items);
    }
    final item = _items.removeAt(oldIndex);
    final target = newIndex.clamp(0, _items.length);
    _items.insert(target, item);
  }

  @override
  ConnectionConfig? getConnection(String id) =>
      _items.where((item) => item.id == id).firstOrNull;

  void trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) {
    final config = getConnection(connectionId);
    if (config == null) throw StateError('Connection not found: $connectionId');
    config.hostKeyAlgorithm = algorithm;
    config.hostKeyFingerprint = fingerprint;
    config.hostKeyTrustedAt = trustedAt;
  }
}

final class _TestCredentialRepository implements CredentialRepository {
  final Map<String, String?> _passwords = {};
  final Map<String, String?> _privateKeys = {};

  @override
  Future<String?> getPassword(String connectionId) async =>
      _passwords[connectionId];

  @override
  Future<String?> getPrivateKey(String connectionId) async =>
      _privateKeys[connectionId];

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    _passwords[connectionId] = password;
    _privateKeys[connectionId] = privateKey;
  }

  @override
  Future<void> deleteCredentials(String connectionId) async {
    _passwords.remove(connectionId);
    _privateKeys.remove(connectionId);
  }
}

final class _TestHostKeyRepository implements HostKeyRepository {
  const _TestHostKeyRepository(this._connections);

  final _TestConnectionRepository _connections;

  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {
    _connections.trustHostKey(
      connectionId,
      algorithm: algorithm,
      fingerprint: fingerprint,
      trustedAt: trustedAt,
    );
  }
}

final class _TestPlaybookRepository implements playbook.PlaybookRepository {
  final List<playbook.Playbook> _items = [];

  @override
  Future<List<playbook.Playbook>> loadPlaybooks() async =>
      List.unmodifiable(_items);

  @override
  Future<void> savePlaybook(playbook.Playbook item) async {
    final index = _items.indexWhere((current) => current.id == item.id);
    final revision = index == -1 ? 1 : _items[index].revision + 1;
    if (index != -1) _items.removeAt(index);
    _items.add(item.copyWith(revision: revision));
  }

  @override
  Future<void> deletePlaybook(String id) async {
    _items.removeWhere((item) => item.id == id);
  }

  @override
  Future<int?> savePlaybookIfRevisionMatches({
    required String playbookId,
    required int expectedRevision,
    required playbook.Playbook playbook,
  }) async {
    final current = _items.where((item) => item.id == playbookId).firstOrNull;
    if (current == null || current.revision != expectedRevision) {
      return null;
    }
    final nextRevision = expectedRevision + 1;
    _items.remove(current);
    _items.add(playbook.copyWith(revision: nextRevision));
    return nextRevision;
  }

  @override
  Future<void> saveRunSnapshot(playbook.PlaybookRunSnapshot snapshot) async {}
}

extension<E> on Iterable<E> {
  E? get firstOrNull {
    for (final item in this) {
      return item;
    }
    return null;
  }
}
