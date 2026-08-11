// v1 原生网络服务命令/事件语义测试。

import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/app/network_v1_adapters.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// 执行 v1 命令接受与终态事件语义测试。
void main() {
  group('NetworkService v1 contract tests', () {
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
      _expectNetworkSuccess(start, 'start unregistered-peer runtime');
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
      _expectNetworkSuccess(start, 'start connect runtime');
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
            _expectNetworkSuccess(start, 'start stress runtime $iteration');
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
      final source = File('${root.path}/native-payload.txt');
      await source.writeAsString('native verified payload');
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
      _expectNetworkSuccess(startA, 'start runtime A');
      _expectNetworkSuccess(startB, 'start runtime B');
      final boundPortA = runtimeA.boundLocalPort;
      final boundPortB = runtimeB.boundLocalPort;
      expect(boundPortA, isNotNull);
      expect(boundPortB, isNotNull);
      final portA = boundPortA!;
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
          endpointAddress: '127.0.0.1:$portA',
          identityPublicKey: publicA,
          e2ePublicKey: Uint8List.fromList(List.filled(32, 41)),
        ),
      );
      _expectNetworkSuccess(upsertA, 'upsert peer B on runtime A');
      _expectNetworkSuccess(upsertB, 'upsert peer A on runtime B');

      final connectedFuture = _firstPeerEvent(
        serviceA,
        (event) =>
            event.peerId == 'device-b' &&
            event.state == PeerConnectionState.connected,
      );
      final connectResult = await serviceA.connect('device-b');
      _expectNetworkSuccess(connectResult, 'connect runtime A to runtime B');
      await connectedFuture.timeout(const Duration(seconds: 10));

      final offerFuture = _firstOffer(serviceB);
      final completedFuture = _firstCompleted(serviceB);
      final sendResult = await serviceA.send(
        transferId: 'native-transfer-1',
        peerId: 'device-b',
        filePath: source.path,
      );
      _expectNetworkSuccess(sendResult, 'send native file');
      final session = (sendResult as NetworkSuccess<TransferSession>).data;
      expect(session.transferId, 'native-transfer-1');
      expect(session.routeType, NetworkRouteType.quicDirect);

      final offer = await offerFuture.timeout(const Duration(seconds: 5));
      expect(offer.fileName, 'native-payload.txt');
      final approve = await serviceB.respondToIncoming(
        transferId: offer.transferId,
        accept: true,
      );
      _expectNetworkSuccess(approve, 'approve incoming native file');

      final completed = await completedFuture.timeout(
        const Duration(seconds: 10),
      );
      expect(completed.localPath, isNotEmpty);
      expect(
        await File(completed.localPath).readAsString(),
        'native verified payload',
      );
    });
  });
}

Future<PeerStateChanged> _firstPeerEvent(
  NetworkService service,
  bool Function(PeerStateChanged event) predicate,
) => service.events
    .where((event) => event is PeerStateChanged)
    .cast<PeerStateChanged>()
    .firstWhere(predicate);

Future<IncomingTransferOffer> _firstOffer(NetworkService service) => service
    .events
    .where((event) => event is IncomingTransferOffer)
    .cast<IncomingTransferOffer>()
    .first;

Future<TransferCompleted> _firstCompleted(NetworkService service) => service
    .events
    .where((event) => event is TransferCompleted)
    .cast<TransferCompleted>()
    .first;

void _expectNetworkSuccess<T>(NetworkResult<T> result, String operation) {
  if (result is NetworkFailure<T>) {
    final error = result.error;
    fail(
      '$operation failed: '
      'code=${error.code.name}; '
      'message=${error.message}; '
      'operation=${error.operation?.wireName ?? '<none>'}; '
      'peerId=${error.peerId ?? '<none>'}',
    );
  }
  expect(
    result,
    isA<NetworkSuccess<T>>(),
    reason: '$operation returned ${result.runtimeType}',
  );
}
