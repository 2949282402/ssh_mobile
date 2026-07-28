import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/network/transfer_transport.dart';
import 'package:ssh_mobile/services/network/network_route_service.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

void main() {
  group('TransferTransport and Route Diagnostics Tests', () {
    test('RouteSnapshot formatting and NetworkRouteService updates', () async {
      final routeService = NetworkRouteService();
      final snapshot = RouteSnapshot(
        peerId: 'peer-1',
        connectionKind: RouteConnectionKind.direct,
        protocolKind: RouteProtocolKind.quic,
        endpointAddress: '2001:db8::1:4433',
        rttMs: 26,
        lossRate: 0.001,
        lastUpdated: DateTime.now(),
      );

      routeService.updateRoute(snapshot);

      final fetched = routeService.getRoute('peer-1');
      expect(fetched, isNotNull);
      expect(fetched!.connectionKind, equals(RouteConnectionKind.direct));
      expect(fetched.rttMs, equals(26));
      expect(fetched.formattedSummary, contains('Direct (QUIC)'));
      expect(fetched.formattedSummary, contains('26 ms'));

      routeService.dispose();
    });

    test('TransferSession model creation', () {
      final session = TransferSession(
        transferId: 't-123',
        peerId: 'peer-1',
        filePath: '/tmp/test.txt',
        transport: TransportKind.quicDirect,
      );

      expect(session.transferId, equals('t-123'));
      expect(session.transport, equals(TransportKind.quicDirect));
    });

    test('QUIC send waits for native command acceptance', () async {
      final directory = await Directory.systemTemp.createTemp(
        'ssh-mobile-network-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.txt');
      await file.writeAsString('payload');
      final runtime = await const SshMobileNetworkNative().createRuntime();
      addTearDown(runtime.dispose);
      final transport = QuicTransferTransport(runtime);
      addTearDown(transport.dispose);

      await expectLater(
        transport.send(
          transferId: 'transfer-1',
          peerId: 'peer-1',
          filePath: file.path,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('peer is not registered'),
          ),
        ),
      );
    });

    test('two native runtimes transfer only after receiver approval', () async {
      final root = await Directory.systemTemp.createTemp(
        'ssh-mobile-native-e2e-',
      );
      final receiveA = Directory('${root.path}/receive-a');
      final receiveB = Directory('${root.path}/receive-b');
      final source = File('${root.path}/native-payload.txt');
      await source.writeAsString('native verified payload');
      addTearDown(() => root.delete(recursive: true));
      final portA = await _availableUdpPort();
      final portB = await _availableUdpPort();
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
      final transportA = QuicTransferTransport(runtimeA);
      final transportB = QuicTransferTransport(runtimeB);
      addTearDown(() async {
        await transportA.dispose();
        await transportB.dispose();
        await runtimeA.dispose();
        await runtimeB.dispose();
      });
      await transportA.configure(
        deviceId: 'device-a',
        identityPrivateKey: identitySeedA,
        e2ePrivateKey: Uint8List.fromList(List.filled(32, 31)),
        listenAddress: '127.0.0.1:$portA',
        receiveDirectory: receiveA.absolute.path,
      );
      await transportB.configure(
        deviceId: 'device-b',
        identityPrivateKey: identitySeedB,
        e2ePrivateKey: Uint8List.fromList(List.filled(32, 32)),
        listenAddress: '127.0.0.1:$portB',
        receiveDirectory: receiveB.absolute.path,
      );
      await expectLater(
        transportA.configureRelay(
          relayUrl: 'http://relay.example.test',
          relayCredential: 'current-protocol-credential',
          relaySigningSeed: Uint8List.fromList(List.filled(32, 55)),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('HTTPS/WSS'),
          ),
        ),
      );
      await transportA.registerPeer(
        peerId: 'device-b',
        endpointAddress: '127.0.0.1:$portB',
        identityPublicKey: publicB,
        e2ePublicKey: Uint8List.fromList(List.filled(32, 42)),
      );
      await transportB.registerPeer(
        peerId: 'device-a',
        endpointAddress: '127.0.0.1:$portA',
        identityPublicKey: publicA,
        e2ePublicKey: Uint8List.fromList(List.filled(32, 41)),
      );
      await transportA.connectPeer('device-b');

      final offerFuture = transportB.incomingOffers.first;
      final receiverCompleted = transportB.events.firstWhere(
        (event) => event.completed,
      );
      final sendFuture = transportA.send(
        transferId: 'native-transfer-1',
        peerId: 'device-b',
        filePath: source.path,
      );
      final offer = await offerFuture.timeout(const Duration(seconds: 5));
      expect(offer.fileName, 'native-payload.txt');
      await transportB.respondToIncoming(
        transferId: offer.transferId,
        accept: true,
      );
      final session = await sendFuture.timeout(const Duration(seconds: 10));
      expect(session.transferId, 'native-transfer-1');
      expect(session.transport, TransportKind.quicDirect);
      final completed = await receiverCompleted.timeout(
        const Duration(seconds: 10),
      );
      expect(completed.localPath, isNotEmpty);
      expect(
        await File(completed.localPath!).readAsString(),
        'native verified payload',
      );
    });
  });
}

Future<int> _availableUdpPort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  socket.close();
  return port;
}
