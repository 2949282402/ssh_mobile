import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'credentials use isolated secure keys and empty values are deleted',
    () async {
      final storage = _MemorySecureStorage();
      final repository = SecureCredentialRepository(storage: storage);

      await repository.saveCredentials(
        connectionId: 'server-1',
        password: 'password-1',
        privateKey: 'key-1',
      );
      expect(await repository.getPassword('server-1'), 'password-1');
      expect(await repository.getPrivateKey('server-1'), 'key-1');
      expect(
        storage.values.keys,
        contains('connection.v2.password.c2VydmVyLTE'),
      );
      expect(
        storage.values.keys,
        contains('connection.v2.private_key.c2VydmVyLTE'),
      );

      await repository.saveCredentials(
        connectionId: 'server-1',
        password: '',
        privateKey: null,
      );
      expect(await repository.getPassword('server-1'), isNull);
      expect(await repository.getPrivateKey('server-1'), isNull);

      await repository.saveCredentials(
        connectionId: 'server-1',
        password: 'password-2',
      );
      await repository.deleteCredentials('server-1');
      expect(storage.values, isEmpty);
    },
  );

  test(
    'non-canonical connection ids are rejected without aliasing secrets',
    () async {
      final storage = _MemorySecureStorage();
      final repository = SecureCredentialRepository(storage: storage);

      expect(() => repository.getPassword(' '), throwsArgumentError);
      await expectLater(
        repository.saveCredentials(connectionId: ''),
        throwsArgumentError,
      );
      await repository.saveCredentials(
        connectionId: 'server',
        password: 'bound-to-server',
      );
      await expectLater(
        repository.saveCredentials(
          connectionId: ' server ',
          password: 'must-not-overwrite',
        ),
        throwsArgumentError,
      );
      expect(await repository.getPassword('server'), 'bound-to-server');
      expect(storage.values.values, isNot(contains('must-not-overwrite')));
    },
  );

  test('encoded secure-storage keys keep distinct ids isolated', () async {
    final storage = _MemorySecureStorage();
    final repository = SecureCredentialRepository(storage: storage);

    await repository.saveCredentials(
      connectionId: 'a',
      password: 'password-a',
      privateKey: 'key-a',
    );
    await repository.saveCredentials(
      connectionId: 'YQ',
      password: 'password-yq',
      privateKey: 'key-yq',
    );

    expect(await repository.getPassword('a'), 'password-a');
    expect(await repository.getPassword('YQ'), 'password-yq');
    expect(storage.values, hasLength(4));
    expect(storage.values.keys.toSet(), hasLength(4));
  });

  test(
    'legacy keys migrate lazily without deleting the only copy first',
    () async {
      final storage = _MemorySecureStorage()
        ..values['connection.password.server-1'] = 'legacy-password'
        ..values['connection.private_key.server-1'] = 'legacy-private-key';
      final repository = SecureCredentialRepository(storage: storage);

      expect(await repository.getPassword('server-1'), 'legacy-password');
      expect(await repository.getPrivateKey('server-1'), 'legacy-private-key');

      expect(storage.values['connection.password.server-1'], isNull);
      expect(storage.values['connection.private_key.server-1'], isNull);
      expect(
        storage.values['connection.v2.password.c2VydmVyLTE'],
        'legacy-password',
      );
      expect(
        storage.values['connection.v2.private_key.c2VydmVyLTE'],
        'legacy-private-key',
      );
    },
  );

  test('failed legacy migration retains the legacy secret', () async {
    final storage = _MemorySecureStorage()
      ..values['connection.password.server-1'] = 'legacy-password'
      ..failNextWrite = true;
    final repository = SecureCredentialRepository(storage: storage);

    await expectLater(repository.getPassword('server-1'), throwsStateError);

    expect(storage.values['connection.password.server-1'], 'legacy-password');
    expect(storage.values['connection.v2.password.c2VydmVyLTE'], isNull);
  });

  test(
    'current credential wins and removes a stale legacy duplicate',
    () async {
      final storage = _MemorySecureStorage()
        ..values['connection.v2.password.c2VydmVyLTE'] = 'current-value'
        ..values['connection.password.server-1'] = 'stale-value';
      final repository = SecureCredentialRepository(storage: storage);

      expect(await repository.getPassword('server-1'), 'current-value');
      expect(storage.values['connection.password.server-1'], isNull);
    },
  );
}

final class _MemorySecureStorage implements SecureStorageClient {
  final Map<String, String> values = {};
  bool failNextWrite = false;

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('secure storage write failed');
    }
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}
