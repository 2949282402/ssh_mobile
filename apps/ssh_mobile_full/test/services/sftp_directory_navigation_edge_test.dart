import 'dart:typed_data';

import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';

import '../test_utils/test_storage_adapter.dart';
import 'sftp_transfer_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('directory failures recover through the last-path fallback', () async {
    final storage = TestStorageAdapter();
    final connection = makeConnection('server-1');
    await storage.connectionRepository.addConnection(connection);
    final remote = MemorySftpClient()
      ..setListing('.', const [])
      ..setListing('/missing', const []);
    final service = SftpService(
      connectionRepository: storage.connectionRepository,
      credentialRepository: storage.credentialRepository,
      hostKeyRepository: storage.hostKeyRepository,
      clientFactory: FakeSshClientFactory(remote),
    );
    addTearDown(() {
      service.dispose();
      storage.dispose();
    });

    await service.connect(connection.id);
    await service.openPath('/missing');
    await service.disconnect();
    await storage.connectionRepository.updateConnection(
      connection.copyWith(host: 'two.example.com'),
    );
    remote.listErrorPaths.add('/missing');

    await service.connect(connection.id);

    expect(service.state, SftpConnectionState.connected);
    expect(service.currentPath, '.');
    expect(service.errorMessage, isNull);
  });

  test('entry operations reject missing and stale session targets', () async {
    final fixture = await makeDetachedFixture(
      bytes: Uint8List.fromList('data'.codeUnits),
    );
    addTearDown(fixture.dispose);
    final validEntry = makeFileEntry(fixture.connection, 'demo.bin', size: 4);
    final missingEntry = SftpEntry(
      connectionId: 'missing',
      targetFingerprint: 'missing-target',
      name: 'demo.bin',
      path: '/srv/demo.bin',
      lowerName: 'demo.bin',
      isDirectory: false,
      isLink: false,
      size: 4,
      sizeLabel: '4 B',
    );
    final staleEntry = SftpEntry(
      connectionId: fixture.connection.id,
      targetFingerprint: 'stale-target',
      name: validEntry.name,
      path: validEntry.path,
      lowerName: validEntry.lowerName,
      isDirectory: false,
      isLink: false,
      size: validEntry.size,
      sizeLabel: validEntry.sizeLabel,
    );

    await expectLater(
      fixture.service.deleteEntry(missingEntry, confirmedName: 'demo.bin'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      fixture.service.deleteEntry(staleEntry, confirmedName: 'demo.bin'),
      throwsA(isA<SftpTargetChangedException>()),
    );
  });

  test(
    'negative read limits fail before opening and close errors are contained',
    () async {
      final fixture = await makeDetachedFixture(
        bytes: Uint8List.fromList('data'.codeUnits),
      );
      addTearDown(fixture.dispose);
      final entry = makeFileEntry(fixture.connection, 'demo.bin', size: 4);

      await expectLater(
        fixture.service.readTextFile(entry, maxBytes: -1),
        throwsArgumentError,
      );
      fixture.remote.closeReadError = StateError('close failed');
      expect(await fixture.service.readTextFile(entry), 'data');
    },
  );

  test('stat path formats byte sizes across all display units', () async {
    final storage = TestStorageAdapter();
    final connection = makeConnection('server-1');
    await storage.connectionRepository.addConnection(connection);
    final remote = _StatSftpClient();
    final service = SftpService(
      connectionRepository: storage.connectionRepository,
      credentialRepository: storage.credentialRepository,
      hostKeyRepository: storage.hostKeyRepository,
      clientFactory: FakeSshClientFactory(remote),
    );
    addTearDown(() {
      service.dispose();
      storage.dispose();
    });

    for (final sample in <({int size, String label})>[
      (size: 512, label: '512 B'),
      (size: 2048, label: '2.0 KB'),
      (size: 2 * 1024 * 1024, label: '2.0 MB'),
      (size: 2 * 1024 * 1024 * 1024, label: '2.0 GB'),
    ]) {
      remote.size = sample.size;
      final info = await service.statPathForConnection(
        connectionId: connection.id,
        path: '/srv/file.bin',
      );
      expect(info.sizeLabel, sample.label);
    }
  });
}

final class _StatSftpClient implements SftpClient {
  int size = 0;

  @override
  Future<String> absolute(String path) async => path;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs(size: size, modifyTime: 1700000000);

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP client call: $invocation');
}
