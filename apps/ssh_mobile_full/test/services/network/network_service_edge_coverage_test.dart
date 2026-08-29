import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';
import 'package:ssh_mobile/services/network/network_service.dart';

import 'transfer_transport_test_support.dart';

void main() {
  test('invalid native frames are ignored at the event boundary', () async {
    final gateway = _SilentGateway();
    final service = NativeNetworkService.fromGateway(gateway);
    addTearDown(() async {
      await service.dispose();
      await gateway.close();
    });

    gateway.emit(Uint8List.fromList(<int>[0xff, 0xff, 0xff]));
    await Future<void>.delayed(Duration.zero);
    expect(
      await service.state('peer-without-route'),
      isA<NetworkFailure<RouteSnapshot>>(),
    );
  });

  test('pending operations are cancelled when the service stops', () async {
    final gateway = _SilentGateway();
    final service = NativeNetworkService.fromGateway(gateway);
    addTearDown(() async {
      await service.dispose();
      await gateway.close();
    });

    final root = await Directory.systemTemp.createTemp('network-edge-');
    addTearDown(() => root.delete(recursive: true));
    final config = NetworkRuntimeConfig(
      deviceId: 'edge-device',
      identityPrivateKey: Uint8List.fromList(List.filled(32, 1)),
      e2ePrivateKey: Uint8List.fromList(List.filled(32, 2)),
      listenAddress: '127.0.0.1:0',
      receiveDirectory: root.path,
    );

    final startFuture = service.start(config);
    await Future<void>.delayed(Duration.zero);
    final stop = await service.stop();
    expect(stop, isA<NetworkSuccess<void>>());
    final start = await startFuture;
    expect(start, isA<NetworkFailure<void>>());
    expect(
      (start as NetworkFailure<void>).error.code,
      NetworkErrorCode.cancelled,
    );

    expect((await service.stop()), isA<NetworkSuccess<void>>());
    expect(
      (await service.disconnect('peer')).errorCode,
      NetworkErrorCode.cancelled,
    );
  });

  test('connect and relay pending waits fail closed on stop', () async {
    final gateway = _SilentGateway();
    final service = NativeNetworkService.fromGateway(gateway);
    addTearDown(() async {
      await service.dispose();
      await gateway.close();
    });

    final connectFuture = service.connect('peer-pending');
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    final connect = await connectFuture;
    expect(connect, isA<NetworkFailure<void>>());

    final secondGateway = _SilentGateway();
    final relayService = NativeNetworkService.fromGateway(secondGateway);
    addTearDown(() async {
      await relayService.dispose();
      await secondGateway.close();
    });
    final relayFuture = relayService.configureRelay(
      RelayConfig(
        relayUrl: 'wss://relay.example.test/ws',
        relayCredential: 'fixture-credential',
        relaySigningSeed: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await relayService.stop();
    final relay = await relayFuture;
    expect(relay, isA<NetworkFailure<void>>());
  });

  test(
    'send accepts a real source file and propagates command failure',
    () async {
      final successGateway = TransferFakeCommandGateway();
      final successService = NativeNetworkService.fromGateway(successGateway);
      addTearDown(() async {
        await successService.dispose();
        await successGateway.close();
      });
      final file = File(
        '${Directory.systemTemp.path}/network-edge-${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await file.writeAsString('fixture payload');
      addTearDown(() => file.delete());
      final accepted = await successService.send(
        transferId: 'transfer-ok',
        peerId: 'peer-ok',
        filePath: file.path,
      );
      expect(accepted, isA<NetworkSuccess<TransferSession>>());
      expect(
        (accepted as NetworkSuccess<TransferSession>).data.filePath,
        file.absolute.path,
      );
      expect((await successService.cancel('transfer-ok')).isSuccess, isTrue);
      expect(
        (await successService.respondToIncoming(
          transferId: 'offer',
          accept: true,
        )).isSuccess,
        isTrue,
      );

      final failureGateway = TransferFakeCommandGateway(
        status: TransportOperationStatus.failure,
      );
      final failureService = NativeNetworkService.fromGateway(failureGateway);
      addTearDown(() async {
        await failureService.dispose();
        await failureGateway.close();
      });
      final failed = await failureService.send(
        transferId: 'transfer-fail',
        peerId: 'peer-fail',
        filePath: file.path,
      );
      expect(failed, isA<NetworkFailure<TransferSession>>());
      expect(
        (failed as NetworkFailure<TransferSession>).error.code,
        NetworkErrorCode.ioError,
      );
    },
  );
}

final class _SilentGateway implements NetworkCommandGateway {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) =>
      TransportOperationStatus.success;

  void emit(Uint8List frame) => _events.add(frame);

  Future<void> close() => _events.close();
}
