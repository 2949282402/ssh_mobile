import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LanStorageService Disk Preflight and Sandbox Adoption', () {
    test(
      'hasSufficientSpace returns true when disk space exceeds required + 100MB buffer',
      () async {
        final storage = LanStorageService(
          sandboxDirectoryProvider: () async => Directory.systemTemp,
          freeDiskSpaceBytesProvider: () async =>
              1024 * 1024 * 1024, // 1 GiB free
        );

        // Required 500 MiB: 1024 - 500 = 524 MiB >= 100 MiB buffer -> true
        expect(await storage.hasSufficientSpace(500 * 1024 * 1024), isTrue);
      },
    );

    test(
      'hasSufficientSpace returns false when disk space is below required + 100MB buffer',
      () async {
        final storage = LanStorageService(
          sandboxDirectoryProvider: () async => Directory.systemTemp,
          freeDiskSpaceBytesProvider: () async =>
              150 * 1024 * 1024, // 150 MiB free
        );

        // Required 100 MiB: 150 - 100 = 50 MiB < 100 MiB buffer -> false
        expect(await storage.hasSufficientSpace(100 * 1024 * 1024), isFalse);
      },
    );

    test(
      'hasSufficientSpace fails closed when disk space query returns null',
      () async {
        final storage = LanStorageService(
          sandboxDirectoryProvider: () async => Directory.systemTemp,
          freeDiskSpaceBytesProvider: () async => null,
        );

        expect(await storage.hasSufficientSpace(1024), isFalse);
      },
    );

    test(
      'hasSufficientSpace fails closed when disk space query throws',
      () async {
        final storage = LanStorageService(
          sandboxDirectoryProvider: () async => Directory.systemTemp,
          freeDiskSpaceBytesProvider: () async =>
              throw const FileSystemException('Space query error'),
        );

        expect(await storage.hasSufficientSpace(1024), isFalse);
      },
    );

    test('hasSufficientSpace uses LanDiskSpacePort correctly', () async {
      final mockPort = _MockDiskSpacePort(
        freeBytes: 80 * 1024 * 1024,
      ); // 80 MiB
      final storage = LanStorageService(
        sandboxDirectoryProvider: () async => Directory.systemTemp,
        diskSpacePort: mockPort,
      );

      // 80 MiB is less than 100 MiB buffer -> false even for 1 byte
      expect(await storage.hasSufficientSpace(1), isFalse);
    });

    test(
      'adoptIncomingNetworkFile falls back to stream copy when rename throws FileSystemException',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'lan-storage-adopt-',
        );
        addTearDown(() => tempDir.delete(recursive: true));

        final sandboxDir = Directory('${tempDir.path}/sandbox')..createSync();
        final inboxDir = Directory('${tempDir.path}/inbox')..createSync();

        final sourceFile = File('${inboxDir.path}/temp_download.bin')
          ..writeAsStringSync('binary content across filesystem boundary');

        final logger = FakeLanShareLogger();
        final storage = LanStorageService(
          sandboxDirectoryProvider: () async => sandboxDir,
          logger: logger,
          renameOverride: (source, target) async {
            throw const FileSystemException('EXDEV: Cross-device link');
          },
        );

        final adoptedFile = await storage.adoptIncomingNetworkFile(
          nativePath: sourceFile.path,
          fileName: 'adopted_file.bin',
        );

        expect(adoptedFile.existsSync(), isTrue);
        expect(
          adoptedFile.readAsStringSync(),
          'binary content across filesystem boundary',
        );
        expect(sourceFile.existsSync(), isFalse);
        expect(adoptedFile.path, startsWith(sandboxDir.path));
      },
    );

    test(
      'deleteSandboxFile only deletes files within sandbox directory',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'lan-storage-delete-',
        );
        addTearDown(() => tempDir.delete(recursive: true));

        final sandboxDir = Directory('${tempDir.path}/sandbox')..createSync();
        final outsideDir = Directory('${tempDir.path}/outside')..createSync();

        final storage = LanStorageService(
          sandboxDirectoryProvider: () async => sandboxDir,
        );

        final insideFile = File('${sandboxDir.path}/inside.txt')
          ..writeAsStringSync('inside');
        final outsideFile = File('${outsideDir.path}/outside.txt')
          ..writeAsStringSync('outside');

        // Deleting inside file succeeds
        expect(await storage.deleteSandboxFile(insideFile.path), isTrue);
        expect(insideFile.existsSync(), isFalse);

        // Deleting outside file is rejected
        expect(await storage.deleteSandboxFile(outsideFile.path), isFalse);
        expect(outsideFile.existsSync(), isTrue);
      },
    );

    test(
      'canonical sandbox lookup failure throws and does not create systemTemp fallback',
      () async {
        final storage = LanStorageService();
        // In Flutter unit tests without path_provider channel mock,
        // getApplicationDocumentsDirectory throws MissingPluginException.
        // It must propagate the error (fail-closed) rather than silently
        // falling back to Directory.systemTemp.
        expect(() => storage.getSandboxDirectory(), throwsA(anything));
      },
    );
  });
}

class _MockDiskSpacePort implements LanDiskSpacePort {
  _MockDiskSpacePort({required this.freeBytes});

  final int? freeBytes;

  @override
  Future<int?> getFreeBytes(Directory targetDirectory) async => freeBytes;
}
