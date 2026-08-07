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
      expect(storage.values.keys, contains('connection.password.server-1'));
      expect(storage.values.keys, contains('connection.private_key.server-1'));

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
    'empty connection ids are rejected before touching secure storage',
    () async {
      final storage = _MemorySecureStorage();
      final repository = SecureCredentialRepository(storage: storage);

      expect(() => repository.getPassword(' '), throwsArgumentError);
      expect(
        () => repository.saveCredentials(connectionId: ''),
        throwsArgumentError,
      );
      expect(storage.values, isEmpty);
    },
  );
}

final class _MemorySecureStorage implements SecureStorageClient {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}
