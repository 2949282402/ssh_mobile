// Network Protocol V2 native transfer and runtime lifecycle tests.

import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:ssh_mobile/services/network/network_service.dart';

import 'transfer_transport_test_support.dart';

/// 执行 V2 transfer、command acceptance 和 native runtime 生命周期测试。
void main() {
  group('NetworkService V2 transfer contract tests', () {
    test('route and error models expose typed state', () {
      const snapshot = RouteSnapshot(
        peerId: 'peer-1',
        routeType: NetworkRouteType.quicDirect,
        endpoint: '2001:db8::1:4433',
        rtt: Duration(milliseconds: 26),
        loss: 0.001,
      );

      expect(snapshot.routeType, NetworkRouteType.quicDirect);
      expect(snapshot.rtt, const Duration(milliseconds: 26));
      expect(NetworkErrorCode.timeout.retryable, isTrue);
      expect(NetworkErrorCode.authenticationFailed.retryable, isFalse);
    });

    test('send rejects an unregistered peer with a typed failure', () async {
      final directory = await Directory.systemTemp.createTemp(
        'ssh-mobile-network-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.txt');
      await file.writeAsString('payload');
      final runtime = await const SshMobileNetworkNative().createRuntime();
      final service = NativeNetworkService(runtime);
      addTearDown(service.dispose);

      final start = await service.start(
        NetworkRuntimeConfig(
          deviceId: 'device-unregistered',
          identityPrivateKey: Uint8List.fromList(List.filled(32, 11)),
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 31)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: directory.absolute.path,
        ),
      );
      expectNetworkSuccess(start, 'start unregistered-peer runtime');
      expect(runtime.boundLocalPort, isNotNull);

      final result = await service.send(
        transferId: 'transfer-1',
        peerId: 'peer-1',
        filePath: file.path,
      );
      expect(result, isA<NetworkFailure<TransferSession>>());
      final failure = result as NetworkFailure<TransferSession>;
      expect(failure.error.code, NetworkErrorCode.noRoute);
      expect(failure.error.operation, NetworkOperation.send);
    });

    test('connect is accepted before the final peer state', () async {
      final root = await Directory.systemTemp.createTemp(
        'ssh-mobile-native-connect-',
      );
      addTearDown(() => root.delete(recursive: true));
      final runtime = await const SshMobileNetworkNative().createRuntime();
      final service = NativeNetworkService(runtime);
      addTearDown(service.dispose);
      final start = await service.start(
        NetworkRuntimeConfig(
          deviceId: 'device-connect',
          identityPrivateKey: Uint8List.fromList(List.filled(32, 12)),
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 32)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: root.absolute.path,
        ),
      );
      expectNetworkSuccess(start, 'start connect runtime');
      expect(runtime.boundLocalPort, isNotNull);

      final connect = await service.connect('not-registered');
      expect(connect, isA<NetworkFailure<void>>());
      final failure = connect as NetworkFailure<void>;
      expect(failure.error.code, NetworkErrorCode.noRoute);
    });

    test(
      'native runtime lifecycle reuses ephemeral ports without retry',
      () async {
        const iterations = 12;
        int? previousPort;

        for (var iteration = 0; iteration < iterations; iteration++) {
          final directory = await Directory.systemTemp.createTemp(
            'ssh-mobile-native-stress-$iteration-',
          );
          final runtime = await const SshMobileNetworkNative().createRuntime();
          final service = NativeNetworkService(runtime);
          try {
            final listenAddress = previousPort == null
                ? '127.0.0.1:0'
                : '127.0.0.1:$previousPort';
            final start = await service.start(
              NetworkRuntimeConfig(
                deviceId: 'device-stress-$iteration',
                identityPrivateKey: Uint8List.fromList(
                  List.filled(32, 80 + iteration),
                ),
                e2ePrivateKey: Uint8List.fromList(
                  List.filled(32, 100 + iteration),
                ),
                listenAddress: listenAddress,
                receiveDirectory: directory.absolute.path,
              ),
            );
            expectNetworkSuccess(start, 'start stress runtime $iteration');
            final boundPort = runtime.boundLocalPort;
            expect(
              boundPort,
              isNotNull,
              reason: 'stress runtime $iteration did not publish its port',
            );
            if (previousPort != null) {
              expect(
                boundPort,
                previousPort,
                reason:
                    'stress runtime $iteration did not reuse the prior port',
              );
            }
            previousPort = boundPort;
          } finally {
            await service.dispose();
            expect(
              runtime.boundLocalPort,
              isNull,
              reason:
                  'stress runtime $iteration retained its port after dispose',
            );
            await directory.delete(recursive: true);
          }
        }
      },
    );

    test('two native runtimes transfer only after receiver approval', () async {
      final root = await Directory.systemTemp.createTemp(
        'ssh-mobile-native-e2e-',
      );
      final receiveA = Directory('${root.path}/receive-a');
      final receiveB = Directory('${root.path}/receive-b');
      addTearDown(() => root.delete(recursive: true));
      final identitySeedA = Uint8List.fromList(List.filled(32, 11));
      final identitySeedB = Uint8List.fromList(List.filled(32, 22));
      final publicA = Uint8List.fromList(
        (await (await Ed25519().newKeyPairFromSeed(
          identitySeedA,
        )).extractPublicKey()).bytes,
      );
      final publicB = Uint8List.fromList(
        (await (await Ed25519().newKeyPairFromSeed(
          identitySeedB,
        )).extractPublicKey()).bytes,
      );
      final runtimeA = await const SshMobileNetworkNative().createRuntime();
      final runtimeB = await const SshMobileNetworkNative().createRuntime();
      final serviceA = NativeNetworkService(runtimeA);
      final serviceB = NativeNetworkService(runtimeB);
      addTearDown(() async {
        await serviceA.dispose();
        await serviceB.dispose();
      });

      final startA = await serviceA.start(
        NetworkRuntimeConfig(
          deviceId: 'device-a',
          identityPrivateKey: identitySeedA,
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 31)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: receiveA.absolute.path,
        ),
      );
      final startB = await serviceB.start(
        NetworkRuntimeConfig(
          deviceId: 'device-b',
          identityPrivateKey: identitySeedB,
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 32)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: receiveB.absolute.path,
        ),
      );
      expectNetworkSuccess(startA, 'start runtime A');
      expectNetworkSuccess(startB, 'start runtime B');
      final boundPortA = runtimeA.boundLocalPort;
      final boundPortB = runtimeB.boundLocalPort;
      expect(boundPortA, isNotNull);
      expect(boundPortB, isNotNull);
      final portB = boundPortB!;

      final upsertA = await serviceA.upsertPeer(
        PeerConfig(
          peerId: 'device-b',
          endpointAddress: '127.0.0.1:$portB',
          identityPublicKey: publicB,
          e2ePublicKey: Uint8List.fromList(List.filled(32, 42)),
        ),
      );
      final upsertB = await serviceB.upsertPeer(
        PeerConfig(
          peerId: 'device-a',
          // Receiver restore only needs identity/E2E trust for passive inbound;
          // it does not need the sender's current endpoint.
          endpointAddress: '',
          identityPublicKey: publicA,
          e2ePublicKey: Uint8List.fromList(List.filled(32, 41)),
        ),
      );
      expectNetworkSuccess(upsertA, 'upsert peer B on runtime A');
      expectNetworkSuccess(upsertB, 'upsert peer A on runtime B');

      final connectedFuture = firstPeerEvent(
        serviceA,
        (event) =>
            event.peerId == 'device-b' &&
            event.state == PeerConnectionState.connected,
      );
      final connectResult = await serviceA.connect('device-b');
      expectNetworkSuccess(connectResult, 'connect runtime A to runtime B');
      await connectedFuture.timeout(const Duration(seconds: 10));

      final fixtures = <(String, int)>[
        ('image.jpg', 1),
        ('archive.zip', 512 * 1024 - 1),
        ('exact-chunk.bin', 512 * 1024),
        ('video.mp4', 512 * 1024 + 1),
        ('large.bin', 2 * 1024 * 1024),
      ];
      for (var index = 0; index < fixtures.length; index++) {
        final (fileName, size) = fixtures[index];
        final source = File('${root.path}/$fileName');
        final payload = Uint8List.fromList(
          List<int>.generate(size, (offset) => (offset + index) % 251),
        );
        await source.writeAsBytes(payload, flush: true);
        final transferId = 'native-transfer-$index';
        final offerFuture = firstOffer(serviceB);
        final completedFuture = firstCompleted(serviceB);
        final sendResult = await serviceA.send(
          transferId: transferId,
          peerId: 'device-b',
          filePath: source.path,
        );
        expectNetworkSuccess(sendResult, 'send $fileName');
        final session = (sendResult as NetworkSuccess<TransferSession>).data;
        expect(session.transferId, transferId);
        expect(session.routeType, NetworkRouteType.quicDirect);

        final offer = await offerFuture.timeout(const Duration(seconds: 5));
        expect(offer.fileName, fileName);
        expect(offer.fileSize, size);
        final approve = await serviceB.respondToIncoming(
          transferId: offer.transferId,
          accept: true,
        );
        expectNetworkSuccess(approve, 'approve $fileName');

        final completed = await completedFuture.timeout(
          const Duration(seconds: 15),
        );
        expect(await File(completed.localPath).readAsBytes(), payload);
      }

      final rejectedSource = File('${root.path}/rejected.bin');
      await rejectedSource.writeAsBytes(<int>[1, 2, 3]);
      final rejectedOfferFuture = firstOffer(serviceB);
      final rejectedFailureFuture = firstFailed(serviceA);
      final rejectedSend = await serviceA.send(
        transferId: 'native-rejected',
        peerId: 'device-b',
        filePath: rejectedSource.path,
      );
      expectNetworkSuccess(rejectedSend, 'offer rejected file');
      final rejectedOffer = await rejectedOfferFuture.timeout(
        const Duration(seconds: 5),
      );
      final reject = await serviceB.respondToIncoming(
        transferId: rejectedOffer.transferId,
        accept: false,
      );
      expectNetworkSuccess(reject, 'reject incoming native file');
      final rejectedFailure = await rejectedFailureFuture.timeout(
        const Duration(seconds: 10),
      );
      expect(rejectedFailure.error.code, NetworkErrorCode.cancelled);
      expect(await File('${receiveB.path}/rejected.bin').exists(), isFalse);
    });
  });
}
