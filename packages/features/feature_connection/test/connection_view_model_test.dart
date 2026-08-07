import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads, verifies and saves a connection through public contracts',
    () async {
      final repository = _FakeConnectionRepository();
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort();
      final verification = _FakeVerificationPort(
        const ConnectionVerificationResult(
          algorithm: 'ssh-ed25519',
          fingerprint: 'MD5:00:01',
          trustedAt: null,
        ),
      );
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: verification,
      );
      addTearDown(viewModel.dispose);

      final config = ConnectionConfig(
        id: 'server-1',
        name: 'Production',
        host: 'prod.example.com',
        username: 'root',
      );
      await viewModel.fetchConnections();
      expect(viewModel.connections, isEmpty);

      final saved = await viewModel.verifyAndSaveConnection(
        config: config,
        isEditing: false,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );

      expect(saved, isTrue);
      expect(verification.calls, 1);
      expect(viewModel.connections.single.hostKeyFingerprint, 'MD5:00:01');
      expect(credentials.passwords['server-1'], 'secret');
      expect(repository.trustedIds, contains('server-1'));
    },
  );

  test(
    'does not save edited configuration when active-window confirmation is rejected',
    () async {
      final repository = _FakeConnectionRepository();
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort()..activeWindows = 2;
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);

      final config = ConnectionConfig(
        id: 'server-1',
        name: 'Production',
        host: 'prod.example.com',
        username: 'root',
      );
      await repository.addConnection(config);
      await viewModel.fetchConnections();

      final saved = await viewModel.verifyAndSaveConnection(
        config: config,
        isEditing: true,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => false,
      );

      expect(saved, isFalse);
      expect(repository.updateCalls, 0);
      expect(runtime.disconnectCalls, 0);
    },
  );

  test('cleans runtime resources and credentials before deleting', () async {
    final repository = _FakeConnectionRepository();
    final credentials = _FakeCredentialRepository()
      ..passwords['server-1'] = 'secret';
    final runtime = _FakeRuntimePort();
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: credentials,
      hostKeyRepository: repository,
      runtimePort: runtime,
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(),
      ),
    );
    addTearDown(viewModel.dispose);

    await repository.addConnection(
      ConnectionConfig(
        id: 'server-1',
        name: 'Production',
        host: 'prod.example.com',
        username: 'root',
      ),
    );
    await viewModel.fetchConnections();
    await viewModel.deleteConnectionWithCleanup('server-1');

    expect(viewModel.connections, isEmpty);
    expect(runtime.cleanedIds, contains('server-1'));
    expect(credentials.deletedIds, contains('server-1'));
  });
}

final class _FakeConnectionRepository
    implements ConnectionRepository, HostKeyRepository {
  final List<ConnectionConfig> _items = [];
  final List<String> trustedIds = [];
  int updateCalls = 0;

  @override
  List<ConnectionConfig> get connections => List.unmodifiable(_items);

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() async => connections;

  @override
  Future<void> addConnection(ConnectionConfig config) async {
    _items.add(ConnectionConfig.fromJson(config.toJson()));
  }

  @override
  Future<void> updateConnection(ConnectionConfig config) async {
    updateCalls++;
    final index = _items.indexWhere((item) => item.id == config.id);
    _items[index] = ConnectionConfig.fromJson(config.toJson());
  }

  @override
  Future<void> deleteConnection(String id) async {
    _items.removeWhere((item) => item.id == id);
  }

  @override
  Future<void> deleteConnections(List<String> ids) async {
    _items.removeWhere((item) => ids.contains(item.id));
  }

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    final item = _items.removeAt(oldIndex);
    _items.insert(newIndex, item);
  }

  @override
  ConnectionConfig? getConnection(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {
    trustedIds.add(connectionId);
    final config = getConnection(connectionId);
    if (config == null) return;
    config.hostKeyAlgorithm = algorithm;
    config.hostKeyFingerprint = fingerprint;
    config.hostKeyTrustedAt = trustedAt;
  }
}

final class _FakeCredentialRepository implements CredentialRepository {
  final Map<String, String?> passwords = {};
  final Map<String, String?> privateKeys = {};
  final List<String> deletedIds = [];

  @override
  Future<String?> getPassword(String connectionId) async =>
      passwords[connectionId];

  @override
  Future<String?> getPrivateKey(String connectionId) async =>
      privateKeys[connectionId];

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    passwords[connectionId] = password;
    privateKeys[connectionId] = privateKey;
  }

  @override
  Future<void> deleteCredentials(String connectionId) async {
    deletedIds.add(connectionId);
    passwords.remove(connectionId);
    privateKeys.remove(connectionId);
  }
}

final class _FakeRuntimePort implements ConnectionRuntimePort {
  int activeWindows = 0;
  int disconnectCalls = 0;
  final List<String> cleanedIds = [];

  @override
  String? get errorMessage => 'fake runtime error';

  @override
  Future<int> activeWindowCount(String connectionId) async => activeWindows;

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {
    disconnectCalls++;
  }

  @override
  Future<void> cleanupConnectionResources(String connectionId) async {
    cleanedIds.add(connectionId);
  }

  @override
  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async => null;
}

final class _FakeVerificationPort implements ConnectionVerificationPort {
  _FakeVerificationPort(this.result);

  final ConnectionVerificationResult result;
  int calls = 0;

  @override
  Future<ConnectionVerificationResult> verify(
    ConnectionConfig config, {
    required String? password,
    required String? privateKey,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    calls++;
    return result;
  }
}
