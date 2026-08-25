import 'dart:io';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LAN V2 sandbox storage', () {
    late Directory root;
    late Directory outsideRoot;
    late LanStorageService storage;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('lan-storage-v2-test-');
      outsideRoot = await Directory.systemTemp.createTemp(
        'lan-outside-v2-test-',
      );
      storage = LanStorageService(sandboxDirectoryProvider: () async => root);
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outsideRoot.exists()) {
        await outsideRoot.delete(recursive: true);
      }
    });

    test('concurrent equal names reserve different files atomically', () async {
      final files = await Future.wait([
        storage.getSandboxTargetFile('report.txt'),
        storage.getSandboxTargetFile('report.txt'),
      ]);

      expect(files[0].path, isNot(equals(files[1].path)));
      expect(await files[0].exists(), isTrue);
      expect(await files[1].exists(), isTrue);
    });

    test('sandbox deletion never deletes an outside file', () async {
      final outside = File('${outsideRoot.path}${Platform.pathSeparator}keep');
      await outside.writeAsString('keep');

      expect(await storage.deleteSandboxFile(outside.path), isFalse);
      expect(await outside.exists(), isTrue);

      final inside = await storage.getSandboxTargetFile('inside.txt');
      await inside.writeAsString('inside');
      expect(await storage.deleteSandboxFile(inside.path), isTrue);
      expect(await inside.exists(), isFalse);
    });
  });
}
