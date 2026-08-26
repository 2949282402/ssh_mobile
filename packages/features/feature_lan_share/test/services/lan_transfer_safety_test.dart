import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_security_service.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_share_models.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_storage_service.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_transfer_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LAN transfer protocol guard', () {
    late LanTransferProtocolGuard guard;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      guard = LanTransferProtocolGuard(
        currentDeviceId: 'local',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
        ),
      );
    });

    test('pairing nonces cannot be replayed', () {
      guard.checkPairingNonce('sender', 'nonce-1234567890');
      expect(
        () => guard.checkPairingNonce('sender', 'nonce-1234567890'),
        throwsA(
          isA<LanHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            HttpStatus.conflict,
          ),
        ),
      );
    });

    test('online pairing attempts are rate limited per address', () {
      for (var attempt = 0; attempt < 8; attempt++) {
        guard.checkPairingAttemptRate('192.168.1.10');
      }
      expect(
        () => guard.checkPairingAttemptRate('192.168.1.10'),
        throwsA(
          isA<LanHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            HttpStatus.tooManyRequests,
          ),
        ),
      );
    });
  });

  group('LAN sandbox storage', () {
    late Directory root;
    late Directory outsideRoot;
    late LanStorageService storage;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('lan-storage-test-');
      outsideRoot = await Directory.systemTemp.createTemp('lan-outside-test-');
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

    test('desktop export copies through a selected directory', () async {
      storage = LanStorageService(
        sandboxDirectoryProvider: () async => root,
        desktopExportDirectoryProvider: () async => outsideRoot.path,
      );
      final source = await storage.getSandboxTargetFile('large-export.bin');
      final payload = List<int>.generate(1024 * 1024, (index) => index % 251);
      await source.writeAsBytes(payload, flush: true);

      expect(
        await storage.exportToPublic(source.path, LanPayloadType.file),
        isTrue,
      );

      final exported = File(
        '${outsideRoot.path}${Platform.pathSeparator}large-export.bin',
      );
      expect(await exported.exists(), isTrue);
      expect(await exported.length(), payload.length);
      expect(await exported.readAsBytes(), payload);
    });
  });
}
