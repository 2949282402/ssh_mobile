import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';

import '../test_utils/test_storage_adapter.dart';

import 'sftp_transfer_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'ssh_mobile_sftp_transfer_',
    );
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => tempDir.path,
        );
    await SftpFileCache.clearAll();
  });

  tearDown(() async {
    await SftpFileCache.clearAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // Windows can briefly keep app.log open after async log writes.
      }
    }
  });

  group('SFTP detached tool transfers', () {
    test('connect resolves a live session and opens the last path', () async {
      final storage = TestStorageAdapter();
      final connection = makeConnection('server-1');
      await storage.connectionRepository.addConnection(connection);
      final remote = MemorySftpClient()
        ..setListing('/', [makeRemoteFile('demo.txt', size: 3)])
        ..setListing('.', [makeRemoteFile('demo.txt', size: 3)]);
      final factory = FakeSshClientFactory(remote);
      final service = SftpService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        clientFactory: factory,
      );
      addTearDown(() {
        service.dispose();
        storage.dispose();
      });

      await service.connect(connection.id);

      expect(factory.connectCount, 1);
      expect(service.state, SftpConnectionState.connected);
      expect(service.entries.single.name, 'demo.txt');
    });

    test(
      'downloadPathForConnection returns bytes and seeds the file cache',
      () async {
        final fixture = await makeDetachedFixture(
          bytes: Uint8List.fromList('remote-data'.codeUnits),
        );
        addTearDown(fixture.dispose);

        final result = await fixture.service.downloadPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv/demo.bin',
        );

        expect(result, 'remote-data'.codeUnits);
        expect(fixture.remote.openReadPaths, contains('/srv/demo.bin'));
        expect(fixture.factory.connectCount, 1);
        expect(fixture.remote.closedReadPaths, contains('/srv/demo.bin'));
      },
    );

    test(
      'downloadPathForConnection serves a cached copy without reopening',
      () async {
        final fixture = await makeDetachedFixture(
          bytes: Uint8List.fromList('cached'.codeUnits),
        );
        addTearDown(fixture.dispose);

        final first = await fixture.service.downloadPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv/demo.bin',
        );
        final second = await fixture.service.downloadPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv/demo.bin',
        );

        expect(first, 'cached'.codeUnits);
        expect(second, 'cached'.codeUnits);
        expect(fixture.remote.openReadCount('/srv/demo.bin'), 1);
        expect(fixture.factory.connectCount, 2);
      },
    );

    test('downloadPathForConnection rejects directory paths', () async {
      final fixture = await makeDetachedFixture(
        bytes: Uint8List(0),
        withDirectory: true,
      );
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.service.downloadPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Directories cannot be downloaded'),
          ),
        ),
      );
    });

    test('downloadPathForConnection propagates remote read failures', () async {
      final fixture = await makeDetachedFixture(
        bytes: Uint8List.fromList('data'.codeUnits),
      );
      addTearDown(fixture.dispose);
      fixture.remote.openError = StateError('Permission denied');

      await expectLater(
        fixture.service.downloadPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv/demo.bin',
        ),
        throwsA(isA<StateError>()),
      );
      expect(fixture.factory.connectCount, 1);
    });

    test('downloadPathForConnection size limit fails before opening', () async {
      final fixture = await makeDetachedFixture(
        bytes: Uint8List.fromList('oversized'.codeUnits),
      );
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.service.downloadPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv/demo.bin',
          maxBytes: 4,
        ),
        throwsA(
          isA<SftpFileSizeLimitException>().having(
            (error) => error.observedBytes,
            'observedBytes',
            9,
          ),
        ),
      );
      expect(fixture.remote.openReadCount('/srv/demo.bin'), 0);
    });

    test(
      'uploadBytesPathForConnection writes and invalidates caches',
      () async {
        final fixture = await makeDetachedFixture(bytes: Uint8List(0));
        addTearDown(fixture.dispose);
        final bytes = Uint8List.fromList('tool-upload'.codeUnits);

        await fixture.service.uploadBytesPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv/out.txt',
          bytes: bytes,
        );

        expect(fixture.remote.fileBytes('/srv/out.txt'), bytes);
        expect(fixture.factory.connectCount, 1);
        expect(fixture.remote.closedWritePaths, contains('/srv/out.txt'));
      },
    );

    test(
      'uploadBytesPathForConnection size limit fails before connecting',
      () async {
        final fixture = await makeDetachedFixture(bytes: Uint8List(0));
        addTearDown(fixture.dispose);

        await expectLater(
          fixture.service.uploadBytesPathForConnection(
            connectionId: fixture.connection.id,
            path: '/srv/out.txt',
            bytes: Uint8List.fromList('big'.codeUnits),
            maxBytes: 2,
          ),
          throwsA(isA<SftpFileSizeLimitException>()),
        );
        expect(fixture.factory.connectCount, 0);
      },
    );

    test('uploadBytesPathForConnection propagates remote failures', () async {
      final fixture = await makeDetachedFixture(bytes: Uint8List(0));
      addTearDown(fixture.dispose);
      fixture.remote.openError = StateError('quota exceeded');

      await expectLater(
        fixture.service.uploadBytesPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv/out.txt',
          bytes: Uint8List.fromList('data'.codeUnits),
        ),
        throwsA(isA<StateError>()),
      );
      expect(fixture.factory.connectCount, 1);
    });
  });
}
