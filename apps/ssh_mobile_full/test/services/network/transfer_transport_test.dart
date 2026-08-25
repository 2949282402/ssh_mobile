// Network Protocol V2 原生网络服务命令/事件语义测试。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';
import 'package:ssh_mobile/services/network/network_service.dart';

/// 执行 V2 命令接受与终态事件语义测试。
void main() {
  group('NetworkService V2 contract tests', () {
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
        final offerFuture = _firstOffer(serviceB);
        final completedFuture = _firstCompleted(serviceB);
        final sendResult = await serviceA.send(
          transferId: transferId,
          peerId: 'device-b',
          filePath: source.path,
        );
        _expectNetworkSuccess(sendResult, 'send $fileName');
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
        _expectNetworkSuccess(approve, 'approve $fileName');

        final completed = await completedFuture.timeout(
          const Duration(seconds: 15),
        );
        expect(await File(completed.localPath).readAsBytes(), payload);
      }

      final rejectedSource = File('${root.path}/rejected.bin');
      await rejectedSource.writeAsBytes(<int>[1, 2, 3]);
      final rejectedOfferFuture = _firstOffer(serviceB);
      final rejectedFailureFuture = _firstFailed(serviceA);
      final rejectedSend = await serviceA.send(
        transferId: 'native-rejected',
        peerId: 'device-b',
        filePath: rejectedSource.path,
      );
      _expectNetworkSuccess(rejectedSend, 'offer rejected file');
      final rejectedOffer = await rejectedOfferFuture.timeout(
        const Duration(seconds: 5),
      );
      final reject = await serviceB.respondToIncoming(
        transferId: rejectedOffer.transferId,
        accept: false,
      );
      _expectNetworkSuccess(reject, 'reject incoming native file');
      final rejectedFailure = await rejectedFailureFuture.timeout(
        const Duration(seconds: 10),
      );
      expect(rejectedFailure.error.code, NetworkErrorCode.cancelled);
      expect(await File('${receiveB.path}/rejected.bin').exists(), isFalse);
    });

    test(
      'gateway facade covers invalid input, status mapping, and lifecycle',
      () async {
        final statusCases = <(TransportOperationStatus, NetworkErrorCode)>[
          (
            TransportOperationStatus.invalidArgument,
            NetworkErrorCode.invalidArgument,
          ),
          (TransportOperationStatus.stopped, NetworkErrorCode.cancelled),
          (TransportOperationStatus.failure, NetworkErrorCode.ioError),
        ];
        for (final (status, expectedCode) in statusCases) {
          final gateway = _FakeCommandGateway(status: status);
          final service = NativeNetworkService.fromGateway(gateway);
          final result = await service.disconnect('peer-a');
          expect(result, isA<NetworkFailure<void>>());
          expect((result as NetworkFailure<void>).error.code, expectedCode);
          await service.dispose();
          await gateway.close();
        }

        final gateway = _FakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        expect(
          (await service.connect('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.disconnect('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.cancel('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.send(
            transferId: '',
            peerId: 'peer-a',
            filePath: '/missing/payload.bin',
          )).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.send(
            transferId: 'transfer-a',
            peerId: 'peer-a',
            filePath: '/missing/payload.bin',
          )).errorCode,
          NetworkErrorCode.ioError,
        );
        expect(
          (await service.state('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.state('peer-a')).errorCode,
          NetworkErrorCode.noRoute,
        );

        final root = await Directory.systemTemp.createTemp(
          'ssh-mobile-gateway-',
        );
        addTearDown(() => root.delete(recursive: true));
        final startConfig = NetworkRuntimeConfig(
          deviceId: 'gateway-device',
          identityPrivateKey: Uint8List.fromList(List.filled(32, 1)),
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 2)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: root.path,
        );
        expect((await service.start(startConfig)).isSuccess, isTrue);
        expect((await service.start(startConfig)).isSuccess, isTrue);
        expect((await service.disconnect('peer-a')).isSuccess, isTrue);

        final routeFrame = _eventFrame(17, <int>[
          ..._bytesField(1, utf8.encode('peer-a')),
          ..._varintField(2, NetworkRouteType.relay.wireValue),
          ..._bytesField(3, utf8.encode('relay.example.test:443')),
        ]);
        gateway.emit(routeFrame);
        await Future<void>.delayed(Duration.zero);
        final route = await service.state('peer-a');
        expect(route, isA<NetworkSuccess<RouteSnapshot>>());
        expect(
          (route as NetworkSuccess<RouteSnapshot>).data.routeType,
          NetworkRouteType.relay,
        );
        expect((await service.connect('peer-a')).isSuccess, isTrue);

        final configureRelayFuture = service.configureRelay(
          RelayConfig(
            relayUrl: 'wss://relay.example.test/ws',
            relayCredential: 'credential',
            relaySigningSeed: Uint8List.fromList(<int>[1, 2, 3]),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        gateway.emit(
          _eventFrame(18, <int>[
            ..._varintField(1, RelayConnectionState.connected.wireValue),
          ]),
        );
        expect((await configureRelayFuture).isSuccess, isTrue);
        expect((await service.disconnectRelay()).isSuccess, isTrue);
        expect((await service.stop()).isSuccess, isTrue);
        expect((await service.stop()).isSuccess, isTrue);
        expect(
          (await service.cancel('transfer-a')).errorCode,
          NetworkErrorCode.cancelled,
        );
      },
    );

    test(
      'gateway events drive failed peer and relay terminal states',
      () async {
        final gateway = _FakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        final connectFuture = service.connect('peer-failed');
        await Future<void>.delayed(Duration.zero);
        gateway.emit(
          _eventFrame(10, <int>[
            ..._bytesField(1, utf8.encode('peer-failed')),
            ..._varintField(2, PeerConnectionState.failed.wireValue),
            ..._bytesField(4, <int>[
              ..._varintField(1, NetworkErrorCode.noRoute.wireValue),
              ..._bytesField(2, utf8.encode('route unavailable')),
            ]),
          ]),
        );
        final connectResult = await connectFuture;
        expect(connectResult.errorCode, NetworkErrorCode.noRoute);

        final relayFuture = service.configureRelay(
          RelayConfig(
            relayUrl: 'wss://relay.example.test/ws',
            relayCredential: 'credential',
            relaySigningSeed: Uint8List.fromList(<int>[4, 5, 6]),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        gateway.emit(
          _eventFrame(18, <int>[
            ..._varintField(1, RelayConnectionState.failed.wireValue),
            ..._bytesField(2, <int>[
              ..._varintField(1, NetworkErrorCode.relayError.wireValue),
              ..._bytesField(2, utf8.encode('relay unavailable')),
            ]),
          ]),
        );
        final relayResult = await relayFuture;
        expect(relayResult.errorCode, NetworkErrorCode.relayError);
      },
    );
  });
}

extension on NetworkResult<Object?> {
  NetworkErrorCode get errorCode => switch (this) {
    NetworkFailure<Object?> failure => failure.error.code,
    _ => fail('Expected a network failure, got $runtimeType'),
  };
}

final class _FakeCommandGateway implements NetworkCommandGateway {
  _FakeCommandGateway({this.status = TransportOperationStatus.success});

  final TransportOperationStatus status;
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  final NetworkProtocolV2Codec _codec = const NetworkProtocolV2Codec();

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    if (status != TransportOperationStatus.success) return status;
    final commandId = _codec.commandId(command);
    scheduleMicrotask(() {
      if (!_events.isClosed) _events.add(_commandResultFrame(commandId));
    });
    return status;
  }

  void emit(Uint8List frame) => _events.add(frame);

  Future<void> close() => _events.close();
}

Uint8List _commandResultFrame(String commandId) => Uint8List.fromList(
  _eventFrame(13, <int>[
    ..._bytesField(1, utf8.encode(commandId)),
    ..._varintField(2, 1),
  ]),
);

Uint8List _eventFrame(int eventField, List<int> payload) =>
    Uint8List.fromList(<int>[
      ..._bytesField(1, utf8.encode('event-a')),
      ..._varintField(2, 1),
      ..._varintField(3, 2),
      ..._bytesField(eventField, payload),
    ]);

List<int> _varintField(int fieldNumber, int value) => <int>[
  ..._varint(fieldNumber << 3),
  ..._varint(value),
];

List<int> _bytesField(int fieldNumber, List<int> value) => <int>[
  ..._varint((fieldNumber << 3) | 2),
  ..._varint(value.length),
  ...value,
];

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    final next = remaining & 0x7f;
    remaining >>= 7;
    bytes.add(remaining == 0 ? next : next | 0x80);
  } while (remaining != 0);
  return bytes;
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

Future<TransferFailed> _firstFailed(NetworkService service) => service.events
    .where((event) => event is TransferFailed)
    .cast<TransferFailed>()
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
