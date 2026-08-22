import 'dart:async';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('wire enums round-trip supported values and fail closed for unknowns', () {
    for (final value in NetworkErrorCode.values) {
      expect(NetworkErrorCode.fromWire(value.wireValue), value);
    }
    for (final value in RetryDisposition.values) {
      expect(RetryDisposition.fromWire(value.wireValue), value);
    }
    for (final value in PeerConnectionState.values) {
      expect(PeerConnectionState.fromWire(value.wireValue), value);
    }
    for (final value in NetworkRouteType.values) {
      expect(NetworkRouteType.fromWire(value.wireValue), value);
    }
    for (final value in NetworkRouteTopology.values) {
      expect(NetworkRouteTopology.fromWire(value.wireValue), value);
    }
    for (final value in NetworkRouteTransport.values) {
      expect(NetworkRouteTransport.fromWire(value.wireValue), value);
    }
    for (final value in RelayConnectionState.values) {
      expect(RelayConnectionState.fromWire(value.wireValue), value);
    }
    for (final value in PeerPresenceState.values) {
      expect(PeerPresenceState.fromWire(value.wireValue), value);
    }
    expect(NetworkErrorCode.fromWire(-1), NetworkErrorCode.unspecified);
    expect(RetryDisposition.fromWire(-1), RetryDisposition.unspecified);
    expect(PeerConnectionState.fromWire(-1), PeerConnectionState.unspecified);
    expect(NetworkRouteType.fromWire(-1), NetworkRouteType.unspecified);
    expect(NetworkRouteTopology.fromWire(-1), NetworkRouteTopology.unspecified);
    expect(NetworkRouteTransport.fromWire(-1), NetworkRouteTransport.unspecified);
    expect(RelayConnectionState.fromWire(-1), RelayConnectionState.unspecified);
    expect(PeerPresenceState.fromWire(-1), PeerPresenceState.unspecified);
  });

  test('network operations accept every wire name and reject null or empty names', () {
    for (final operation in NetworkOperation.values) {
      expect(NetworkOperation.fromWire(operation.wireName), operation);
    }
    expect(NetworkOperation.fromWire(null), isNull);
    expect(NetworkOperation.fromWire(''), isNull);
    expect(NetworkOperation.fromWire('unknown-operation'), isNull);
  });

  test('network errors preserve retry overrides and copy fields', () {
    const base = NetworkError(
      code: NetworkErrorCode.noRoute,
      message: 'no route',
      operation: NetworkOperation.connect,
      peerId: 'peer-a',
    );
    expect(base.retryable, isTrue);
    expect(base.toString(), contains('noRoute'));

    final copied = base.copyWith(
      code: NetworkErrorCode.authenticationFailed,
      message: 'auth failed',
      operation: NetworkOperation.refreshCredential,
      peerId: 'peer-b',
      retryDisposition: RetryDisposition.noRetry,
      retryAfterSeconds: 4,
    );
    expect(copied.code, NetworkErrorCode.authenticationFailed);
    expect(copied.message, 'auth failed');
    expect(copied.operation, NetworkOperation.refreshCredential);
    expect(copied.peerId, 'peer-b');
    expect(copied.retryDisposition, RetryDisposition.noRetry);
    expect(copied.retryAfterSeconds, 4);
    expect(copied.retryable, isFalse);

    for (final disposition in const [
      RetryDisposition.retryWithBackoff,
      RetryDisposition.retryAfter,
      RetryDisposition.refreshCredentialThenRetry,
    ]) {
      expect(base.copyWith(retryDisposition: disposition).retryable, isTrue);
    }
  });

  test('configuration, route, transfer, result, and event models retain values', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);
    const error = NetworkError(
      code: NetworkErrorCode.ioError,
      message: 'io',
      operation: NetworkOperation.send,
      peerId: 'peer-a',
    );
    const route = SdkRouteSnapshot(
      peerId: 'peer-a',
      routeType: NetworkRouteType.quicDirect,
      topology: NetworkRouteTopology.direct,
      transport: NetworkRouteTransport.quic,
      endpoint: '127.0.0.1:443',
      rtt: Duration(milliseconds: 12),
      loss: 0.25,
    );

    final runtime = SdkRuntimeConfig(
      deviceId: 'device-a',
      identityPrivateKey: bytes,
      e2ePrivateKey: bytes,
      listenAddress: '127.0.0.1:0',
      receiveDirectory: '/tmp/receive',
    );
    final peer = SdkPeerConfig(
      peerId: 'peer-a',
      endpointAddress: 'quic://127.0.0.1:443',
      identityPublicKey: bytes,
      e2ePublicKey: bytes,
    );
    final relay = SdkRelayConfig(
      relayUrl: 'https://relay.example',
      relayCredential: 'credential',
      relaySigningSeed: bytes,
    );
    const transfer = SdkTransferSession(
      transferId: 'transfer-a',
      peerId: 'peer-a',
      filePath: '/tmp/file',
      routeType: NetworkRouteType.relay,
    );
    expect(runtime.deviceId, 'device-a');
    expect(peer.endpointAddress, startsWith('quic://'));
    expect(relay.relayUrl, contains('relay'));
    expect(transfer.routeType, NetworkRouteType.relay);
    expect(route.transport, NetworkRouteTransport.quic);

    final events = <SdkEvent>[
      PeerStateChanged(
        eventId: '1',
        timestamp: timestamp,
        peerId: 'peer-a',
        state: PeerConnectionState.connected,
        routeType: NetworkRouteType.quicDirect,
        routeTopology: NetworkRouteTopology.direct,
        routeTransport: NetworkRouteTransport.quic,
        error: error,
      ),
      TransferProgress(
        eventId: '2',
        timestamp: timestamp,
        transferId: 'transfer-a',
        bytesTransferred: 2,
        totalBytes: 3,
      ),
      TransferCompleted(
        eventId: '3',
        timestamp: timestamp,
        transferId: 'transfer-a',
        localPath: '/tmp/file',
      ),
      TransferFailed(
        eventId: '4',
        timestamp: timestamp,
        transferId: 'transfer-a',
        error: error,
      ),
      IncomingTransferOffer(
        eventId: '5',
        timestamp: timestamp,
        transferId: 'transfer-a',
        peerId: 'peer-a',
        fileName: 'file.bin',
        fileSize: 3,
        routeType: NetworkRouteType.relay,
      ),
      RouteChanged(eventId: '6', timestamp: timestamp, snapshot: route),
      RelayStateChanged(
        eventId: '7',
        timestamp: timestamp,
        state: RelayConnectionState.connected,
        error: error,
      ),
      PeerPresenceChanged(
        eventId: '8',
        timestamp: timestamp,
        peerId: 'peer-a',
        generation: 2,
        state: PeerPresenceState.online,
      ),
      PeerPresenceSnapshot(
        eventId: '9',
        timestamp: timestamp,
        peers: <PeerPresenceChanged>[],
      ),
    ];
    expect(events, hasLength(9));
    expect((events[0] as PeerStateChanged).error, same(error));
    expect((events[1] as TransferProgress).totalBytes, 3);
    expect((events[2] as TransferCompleted).localPath, '/tmp/file');
    expect((events[3] as TransferFailed).error.code, NetworkErrorCode.ioError);
    expect((events[4] as IncomingTransferOffer).fileName, 'file.bin');
    expect((events[5] as RouteChanged).snapshot.rtt, const Duration(milliseconds: 12));
    expect((events[6] as RelayStateChanged).state, RelayConnectionState.connected);
    expect((events[7] as PeerPresenceChanged).generation, 2);
    expect((events[8] as PeerPresenceSnapshot).peers, isEmpty);
  });

  test('typed SDK results and disposed exception expose stable state', () {
    const success = SdkSuccess<int>(7);
    const failure = SdkFailure<int>(
      NetworkError(code: NetworkErrorCode.cancelled, message: 'cancelled'),
    );
    expect(success.isSuccess, isTrue);
    expect(success.data, 7);
    expect(failure.isSuccess, isFalse);
    expect(failure.error.code, NetworkErrorCode.cancelled);
    expect(const SdkClientDisposedException().toString(), 'SdkClientDisposedException');
  });

  test('high-level NetworkFacade delegates every session operation', () async {
    final sessions = _FacadeSessionStub();
    final facade = NetworkFacadeImpl(sessions: sessions);
    final config = SdkRuntimeConfig(
      deviceId: 'device-a',
      identityPrivateKey: Uint8List.fromList(<int>[1]),
      e2ePrivateKey: Uint8List.fromList(<int>[2]),
      listenAddress: '127.0.0.1:0',
      receiveDirectory: '/tmp/receive',
    );
    final peer = SdkPeerConfig(
      peerId: 'peer-a',
      endpointAddress: 'quic://127.0.0.1:443',
      identityPublicKey: Uint8List.fromList(<int>[3]),
      e2ePublicKey: Uint8List.fromList(<int>[4]),
    );
    final relay = SdkRelayConfig(
      relayUrl: 'https://relay.example',
      relayCredential: 'credential',
      relaySigningSeed: Uint8List.fromList(<int>[5]),
    );

    expect(facade.events, same(sessions.events));
    expect(await facade.start(config), isA<SdkSuccess<void>>());
    expect(await facade.stop(), isA<SdkSuccess<void>>());
    expect(
      await facade.connectPeer('peer-a', peer: peer),
      isA<SdkSuccess<void>>(),
    );
    expect(await facade.disconnectPeer('peer-a'), isA<SdkSuccess<void>>());
    expect(await facade.configureRelay(relay), isA<SdkSuccess<void>>());
    expect(await facade.disconnectRelay(), isA<SdkSuccess<void>>());
    expect(
      await facade.transferFile(
        transferId: 'transfer-a',
        peerId: 'peer-a',
        filePath: '/tmp/file',
      ),
      isA<SdkSuccess<SdkTransferSession>>(),
    );
    expect(await facade.cancelTransfer('transfer-a'), isA<SdkSuccess<void>>());
    expect(
      await facade.respondToIncomingTransfer(
        transferId: 'transfer-a',
        accept: true,
      ),
      isA<SdkSuccess<void>>(),
    );
    expect(
      await facade.sendMessage(
        peerId: 'peer-a',
        payload: Uint8List.fromList(<int>[6]),
      ),
      isA<SdkFailure<void>>(),
    );
    expect(await facade.peerState('peer-a'), isA<SdkSuccess<SdkRouteSnapshot>>());
    expect(
      () => facade.createRealtimeSession(realtimeId: 'rt-a', peerId: 'peer-a'),
      throwsUnsupportedError,
    );

    await facade.dispose();
    expect(sessions.disposed, isTrue);
    expect(() => facade.peerState('peer-a'), throwsA(isA<SdkClientDisposedException>()));
  });
}

final class _FacadeSessionStub implements SessionClient {
  @override
  final Stream<SdkEvent> events = const Stream<SdkEvent>.empty();

  bool disposed = false;

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> connect(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> disconnect(String peerId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> disconnectRelay() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkTransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) async => SdkSuccess(
    SdkTransferSession(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
      routeType: NetworkRouteType.unspecified,
    ),
  );

  @override
  Future<SdkResult<void>> cancel(String transferId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkRouteSnapshot>> state(String peerId) async => SdkSuccess(
    SdkRouteSnapshot(peerId: peerId, routeType: NetworkRouteType.unspecified),
  );

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
