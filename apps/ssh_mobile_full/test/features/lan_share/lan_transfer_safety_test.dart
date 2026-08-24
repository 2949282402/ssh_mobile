import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LAN transfer protocol guard', () {
    late LanTransferProtocolGuard guard;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      guard = LanTransferProtocolGuard(
        currentDeviceId: 'local',
        securityService: LanSecurityService(),
      );
    });

    test('pending uploads are isolated by sender identity', () {
      final expiry = DateTime.now().add(const Duration(minutes: 1));
      guard.registerPendingUpload(
        LanPendingUpload(
          messageId: 'same-id',
          senderDeviceId: 'sender-a',
          fileName: 'a.bin',
          expectedBytes: 10,
          encrypted: false,
          expiresAt: expiry,
        ),
      );
      guard.registerPendingUpload(
        LanPendingUpload(
          messageId: 'same-id',
          senderDeviceId: 'sender-b',
          fileName: 'b.bin',
          expectedBytes: 20,
          encrypted: false,
          expiresAt: expiry,
        ),
      );

      expect(
        guard
            .consumePendingUpload(
              messageId: 'same-id',
              senderDeviceId: 'sender-a',
              fileName: 'a.bin',
              encrypted: false,
            )
            .expectedBytes,
        10,
      );
      final senderBUpload = guard.consumePendingUpload(
        messageId: 'same-id',
        senderDeviceId: 'sender-b',
        fileName: 'b.bin',
        encrypted: false,
      );
      expect(senderBUpload.expectedBytes, 20);
      guard.completeUpload(senderBUpload);
    });

    test('encrypted uploads above the memory budget are rejected', () {
      expect(
        () => guard.registerPendingUpload(
          LanPendingUpload(
            messageId: 'large',
            senderDeviceId: 'sender',
            fileName: 'large.bin',
            expectedBytes: LanTransferProtocolGuard.maxEncryptedUploadBytes + 1,
            encrypted: true,
            expiresAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
        ),
        throwsA(
          isA<LanHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            HttpStatus.requestEntityTooLarge,
          ),
        ),
      );
    });

    test('pending upload sessions are bounded', () {
      for (
        var index = 0;
        index < LanTransferProtocolGuard.maxPendingUploadSessions;
        index++
      ) {
        guard.registerPendingUpload(
          LanPendingUpload(
            messageId: 'message-$index',
            senderDeviceId: 'sender',
            fileName: 'file-$index.bin',
            expectedBytes: 1,
            encrypted: false,
            expiresAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
        );
      }

      expect(
        () => guard.registerPendingUpload(
          LanPendingUpload(
            messageId: 'overflow',
            senderDeviceId: 'sender',
            fileName: 'overflow.bin',
            expectedBytes: 1,
            encrypted: false,
            expiresAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
        ),
        throwsA(
          isA<LanHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            HttpStatus.tooManyRequests,
          ),
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
  });
}
