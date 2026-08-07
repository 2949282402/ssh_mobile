import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ConnectionDatabase database;
  late DriftConnectionRepository repository;

  setUp(() {
    database = ConnectionDatabase.forTesting(NativeDatabase.memory());
    repository = DriftConnectionRepository(database: database);
  });

  tearDown(() => database.dispose());

  test(
    'CRUD persists structure but never persists password or private key',
    () async {
      final source = _connection(
        id: 'server-1',
        password: 'secret-password',
        privateKey: 'secret-private-key',
      );

      await repository.addConnection(source);
      expect(repository.connections.single.password, isNull);
      expect(repository.connections.single.privateKey, isNull);

      final row = await database.select(database.connectionTable).getSingle();
      expect(row.id, 'server-1');
      expect(row.host, 'server-1.example.com');

      await repository.updateConnection(
        source.copyWith(name: 'Updated', host: 'updated.example.com'),
      );
      expect(repository.getConnection('server-1')?.name, 'Updated');
      expect(repository.getConnection('server-1')?.host, 'updated.example.com');

      await repository.deleteConnection('server-1');
      expect(repository.connections, isEmpty);
      expect(await database.select(database.connectionTable).get(), isEmpty);
    },
  );

  test('concurrent additions are serialized and reorder is durable', () async {
    await Future.wait([
      repository.addConnection(_connection(id: 'server-a')),
      repository.addConnection(_connection(id: 'server-b')),
      repository.addConnection(_connection(id: 'server-c')),
    ]);
    expect(repository.connections.map((item) => item.id), [
      'server-a',
      'server-b',
      'server-c',
    ]);

    await repository.reorderConnections(0, 2);
    expect(repository.connections.map((item) => item.id), [
      'server-b',
      'server-c',
      'server-a',
    ]);

    final reloaded = await repository.loadConnections();
    expect(reloaded.map((item) => item.id), [
      'server-b',
      'server-c',
      'server-a',
    ]);
  });

  test('Host Key trust updates only the selected connection', () async {
    await repository.addConnection(_connection(id: 'server-a'));
    await repository.addConnection(_connection(id: 'server-b'));

    await repository.trustHostKey(
      'server-b',
      algorithm: 'ssh-ed25519',
      fingerprint: 'SHA256:trusted',
      trustedAt: DateTime.utc(2040),
    );

    expect(repository.getConnection('server-a')?.hostKeyFingerprint, isNull);
    expect(
      repository.getConnection('server-b')?.hostKeyFingerprint,
      'SHA256:trusted',
    );
    expect(
      repository.getConnection('server-b')?.hostKeyAlgorithm,
      'ssh-ed25519',
    );
  });

  test('missing CRUD targets fail explicitly', () async {
    await repository.initialize();
    await expectLater(
      repository.updateConnection(_connection(id: 'missing')),
      throwsStateError,
    );
    expect(repository.getConnection('missing'), isNull);
  });
}

ConnectionConfig _connection({
  required String id,
  String? password,
  String? privateKey,
}) {
  return ConnectionConfig(
    id: id,
    name: id,
    host: '$id.example.com',
    username: 'tester',
    password: password,
    privateKey: privateKey,
  );
}
