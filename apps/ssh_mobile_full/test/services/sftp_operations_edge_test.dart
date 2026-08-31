import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';

import 'sftp_transfer_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'detached directory and file operations preserve cache boundaries',
    () async {
      final fixture = await makeDetachedFixture(
        bytes: Uint8List.fromList('hello'.codeUnits),
      );
      addTearDown(fixture.dispose);
      fixture.remote
        ..setFile('/srv/hello.txt', Uint8List.fromList('hello'.codeUnits))
        ..setListing('/srv', [
          makeRemoteFile('hello.txt', size: 5),
          SftpName(
            filename: 'folder',
            longname: 'folder',
            attr: SftpFileAttrs(
              size: 0,
              mode: SftpFileMode.value(1 << 14),
              modifyTime: null,
            ),
          ),
        ]);

      expect(fixture.service.connectionId, fixture.connection.id);
      expect(fixture.service.connectionName, fixture.connection.name);
      expect(
        fixture.service.getSftpClientForConnection(fixture.connection.id),
        same(fixture.remote),
      );
      expect(fixture.service.isConnectionOpen(fixture.connection.id), isTrue);
      expect(fixture.service.isConnectionBusy(fixture.connection.id), isFalse);
      expect(fixture.service.isConnectionBusy('missing-connection'), isFalse);
      expect(
        () => SftpService.forTesting(
          fixture.storage.connectionRepository,
          fixture.storage.credentialRepository,
          fixture.storage.hostKeyRepository,
          connection: fixture.connection,
          sftpClient: fixture.remote,
          telemetryFailureTimeout: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );

      final firstListing = await fixture.service.listDirectoryForConnection(
        fixture.connection.id,
        '/srv',
      );
      final secondListing = await fixture.service.listDirectoryForConnection(
        fixture.connection.id,
        '/srv',
      );
      expect(firstListing.map((entry) => entry.name), ['folder', 'hello.txt']);
      expect(secondListing, same(firstListing));
      expect(fixture.remote.listCount('/srv'), 1);

      expect(
        await fixture.service.readTextPathForConnection(
          connectionId: fixture.connection.id,
          path: '/srv/hello.txt',
        ),
        'hello',
      );
      await fixture.service.writeTextPathForConnection(
        connectionId: fixture.connection.id,
        path: '/srv/hello.txt',
        text: 'updated',
      );
      expect(fixture.remote.fileBytes('/srv/hello.txt'), 'updated'.codeUnits);

      final stat = await fixture.service.statPathForConnection(
        connectionId: fixture.connection.id,
        path: '/srv/hello.txt',
      );
      expect(stat.path, '/srv/hello.txt');
      expect(stat.isDirectory, isFalse);
      expect(stat.size, 7);
      expect(stat.sizeLabel, '7 B');
      expect(stat.modifiedAt, isNotNull);

      await fixture.service.createDirectoryPathForConnection(
        connectionId: fixture.connection.id,
        path: '/srv/new-folder',
      );
      expect(fixture.remote.createdDirectories, contains('/srv/new-folder'));

      await fixture.service.renamePathForConnection(
        connectionId: fixture.connection.id,
        path: '/srv/hello.txt',
        newPath: '/srv/renamed.txt',
      );
      expect(fixture.remote.renamedPaths['/srv/hello.txt'], '/srv/renamed.txt');
      expect(fixture.remote.fileBytes('/srv/renamed.txt'), 'updated'.codeUnits);

      await fixture.service.deletePathForConnection(
        connectionId: fixture.connection.id,
        path: '/srv/new-folder',
      );
      expect(fixture.remote.removedDirectories, contains('/srv/new-folder'));
      await fixture.service.deletePathForConnection(
        connectionId: fixture.connection.id,
        path: '/srv/renamed.txt',
      );
      expect(fixture.remote.removedPaths, contains('/srv/renamed.txt'));

      final recent = await fixture.service.loadRecentPaths(
        fixture.connection.id,
        limit: 5,
      );
      expect(recent, isA<List<SftpRecentPathRecord>>());
      final favorite = await fixture.service.addFavoritePath(
        fixture.connection.id,
        '/srv',
        'Server root',
      );
      expect(favorite.path, '/srv');
      expect(
        await fixture.service.findFavoritePath(fixture.connection.id, '/srv'),
        same(favorite),
      );
      expect(
        (await fixture.service.loadFavoritePaths(fixture.connection.id)).single,
        same(favorite),
      );
      await fixture.service.removeFavoritePath(favorite.id);
      expect(
        await fixture.service.findFavoritePath(fixture.connection.id, '/srv'),
        isNull,
      );
    },
  );

  test(
    'connected editor operations navigate, save, and report failures',
    () async {
      final connection = makeConnection('editor-server');
      final remote = MemorySftpClient()
        ..setFile('/srv/edit.txt', Uint8List.fromList('before'.codeUnits))
        ..setListing('/srv', [makeRemoteFile('edit.txt', size: 6)])
        ..setListing('/srv/sub', const [])
        ..setListing('/srv/sub/', const [])
        ..setListing('/', const []);
      final fixture = TransferFixture(
        connection: connection,
        remote: remote,
        entry: makeFileEntry(connection, 'edit.txt', size: 6),
        currentPath: '/srv',
      );
      addTearDown(fixture.dispose);

      await fixture.service.openPath('/srv/sub');
      expect(fixture.service.currentPath, '/srv/sub');
      await fixture.service.openParent();
      expect(fixture.service.currentPath, '/srv');
      await fixture.service.openPath('/srv/sub/');
      await fixture.service.openParent();
      expect(fixture.service.currentPath, '/srv');
      await fixture.service.refresh();
      expect(fixture.service.entries.single.name, 'edit.txt');

      expect(await fixture.service.readTextFile(fixture.entry), 'before');
      await fixture.service.saveTextFile(fixture.entry, 'after');
      expect(remote.fileBytes('/srv/edit.txt'), 'after'.codeUnits);
      expect(fixture.service.state, SftpConnectionState.connected);

      await expectLater(
        fixture.service.deleteEntry(fixture.entry, confirmedName: 'wrong'),
        throwsA(isA<StateError>()),
      );

      remote.removeError = StateError('remote delete denied');
      await fixture.service.deleteEntry(
        fixture.entry,
        confirmedName: fixture.entry.name,
      );
      expect(fixture.service.state, SftpConnectionState.error);
      expect(fixture.service.errorMessage, contains('Delete failed'));

      remote.removeError = null;
      remote.writeError = StateError('remote write denied');
      await expectLater(
        fixture.service.saveTextFile(fixture.entry, 'again'),
        throwsA(isA<StateError>()),
      );
      expect(fixture.service.state, SftpConnectionState.error);
      expect(fixture.service.errorMessage, contains('Save failed'));

      await fixture.service.openPath('/');
      await fixture.service.openParent();
      expect(fixture.service.currentPath, '/');

      await fixture.service.disconnect(notify: false);
      await fixture.service.openPath('/');
      expect(fixture.service.currentPath, '.');

      await fixture.service.openPath('/srv');
      await fixture.service.openParent();
      expect(fixture.service.currentPath, '.');
    },
  );
}
