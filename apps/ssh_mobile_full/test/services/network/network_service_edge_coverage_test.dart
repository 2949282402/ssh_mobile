import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
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
    'command rejection maps typed errors and releases relay waiters',
    () async {
      final gateway = _RejectingGateway();
      final service = NativeNetworkService.fromGateway(gateway);
      addTearDown(() async {
        await service.dispose();
        await gateway.close();
      });

      final connect = await service.connect('peer-rejected');
      expect(connect, isA<NetworkFailure<void>>());
      expect(
        (connect as NetworkFailure<void>).error.code,
        NetworkErrorCode.noRoute,
      );
      expect(
        connect.error.operation,
        NetworkOperation.connect,
      );

      final relay = await service.configureRelay(
        RelayConfig(
          relayUrl: 'wss://relay.example.test/ws',
          relayCredential: 'credential',
          relaySigningSeed: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      );
      expect(relay, isA<NetworkFailure<void>>());
      expect(
        (relay as NetworkFailure<void>).error.code,
        NetworkErrorCode.noRoute,
      );
      expect(
        relay.error.operation,
        NetworkOperation.configureRelay,
      );
    },
  );

  test(
    'failed peer event without an error uses the no-route fallback',
    () async {
      final gateway = TransferFakeCommandGateway();
      final service = NativeNetworkService.fromGateway(gateway);
      addTearDown(() async {
        await service.dispose();
        await gateway.close();
      });

      final connectFuture = service.connect('peer-no-error');
      await Future<void>.delayed(Duration.zero);
      gateway.emit(
        transferEventFrame(10, <int>[
          ...transferBytesField(1, utf8.encode('peer-no-error')),
          ...transferVarintField(2, PeerConnectionState.failed.wireValue),
        ]),
      );
      final result = await connectFuture;
      expect(result, isA<NetworkFailure<void>>());
      expect(
        (result as NetworkFailure<void>).error.code,
        NetworkErrorCode.noRoute,
      );
      expect(result.error.peerId, 'peer-no-error');
    },
  );

  test(
    'transfer offers and terminal events update the public projection',
    () async {
      final gateway = TransferFakeCommandGateway();
      final service = NativeNetworkService.fromGateway(gateway);
      addTearDown(() async {
        await service.dispose();
        await gateway.close();
      });

      final offerFuture = firstOffer(service);
      gateway.emit(
        transferEventFrame(14, <int>[
          ...transferBytesField(1, utf8.encode('offer-1')),
          ...transferBytesField(2, utf8.encode('peer-1')),
          ...transferBytesField(3, utf8.encode('report.txt')),
          ...transferVarintField(4, 12),
          ...transferVarintField(5, NetworkRouteType.quicDirect.wireValue),
        ]),
      );
      final offer = await offerFuture;
      expect(offer.transferId, 'offer-1');
      expect(offer.peerId, 'peer-1');
      expect(offer.fileName, 'report.txt');
      expect(offer.fileSize, 12);

      final completedFuture = firstCompleted(service);
      gateway.emit(
        transferEventFrame(15, <int>[
          ...transferBytesField(1, utf8.encode('offer-1')),
          ...transferBytesField(2, utf8.encode('/tmp/report.txt')),
        ]),
      );
      expect((await completedFuture).localPath, '/tmp/report.txt');

      final failedFuture = firstFailed(service);
      gateway.emit(
        transferEventFrame(16, <int>[
          ...transferBytesField(1, utf8.encode('offer-2')),
          ...transferBytesField(2, <int>[
            ...transferVarintField(1, NetworkErrorCode.ioError.wireValue),
            ...transferBytesField(2, utf8.encode('write failed')),
          ]),
        ]),
      );
      expect((await failedFuture).error.code, NetworkErrorCode.ioError);
    },
  );

  test(
    'owned native runtime follows explicit stop and already-stopped status',
    () async {
      final directory = await Directory.systemTemp.createTemp('network-owned-');
      addTearDown(() => directory.delete(recursive: true));
      final runtime = await const SshMobileNetworkNative().createRuntime();
      final service = NativeNetworkService(runtime);
      addTearDown(service.dispose);
      final config = NetworkRuntimeConfig(
        deviceId: 'owned-runtime-device',
        identityPrivateKey: Uint8List.fromList(List.filled(32, 21)),
        e2ePrivateKey: Uint8List.fromList(List.filled(32, 22)),
        listenAddress: '127.0.0.1:0',
        receiveDirectory: directory.path,
      );
      expect((await service.start(config)).isSuccess, isTrue);
      expect((await service.stop()).isSuccess, isTrue);
      expect((await service.stop()).isSuccess, isTrue);
    },
  );

  test(
    'runtime gateway maps a stopped native handle to cancellation',
    () async {
      final runtime = await const SshMobileNetworkNative().createRuntime();
      await runtime.stop();
      final service = NativeNetworkService(runtime);
      addTearDown(service.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'network-stopped-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final result = await service.start(
        NetworkRuntimeConfig(
          deviceId: 'stopped-runtime-device',
          identityPrivateKey: Uint8List.fromList(List.filled(32, 23)),
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 24)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: directory.path,
        ),
      );
      expect(result, isA<NetworkFailure<void>>());
      expect(
        (result as NetworkFailure<void>).error.code,
        NetworkErrorCode.cancelled,
      );
    },
  );

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

final class _RejectingGateway implements NetworkCommandGateway {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  final NetworkProtocolV2Codec _codec = const NetworkProtocolV2Codec();

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    final commandId = _codec.commandId(command);
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events.add(
        transferEventFrame(13, <int>[
          ...transferBytesField(1, utf8.encode(commandId)),
          ...transferVarintField(2, 0),
          ...transferBytesField(3, <int>[
            ...transferVarintField(1, NetworkErrorCode.noRoute.wireValue),
            ...transferBytesField(2, utf8.encode('route unavailable')),
          ]),
        ]),
      );
    });
    return TransportOperationStatus.success;
  }

  Future<void> close() => _events.close();
}
