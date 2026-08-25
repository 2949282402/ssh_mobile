import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test(
    'sendFile rejects missing sources before any network operation',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      final result = await fixture.coordinator.sendFile(
        _device('peer-a'),
        '/tmp/does-not-exist-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(result, isA<SdkFailure<SdkTransferSession>>());
      expect(
        (result as SdkFailure<SdkTransferSession>).error.code,
        NetworkErrorCode.ioError,
      );
      expect(fixture.facade.connectCalls, 0);
      expect(fixture.facade.transferCalls, 0);
    },
  );

  test(
    'sendFile rejects directories and untrusted peers without HTTPS fallback',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final directory = await Directory.systemTemp.createTemp('lan-v2-source-');
      addTearDown(() => directory.delete(recursive: true));

      final directoryResult = await fixture.coordinator.sendFile(
        _device('peer-a'),
        directory.path,
      );
      expect(directoryResult, isA<SdkFailure<SdkTransferSession>>());
      expect(
        (directoryResult as SdkFailure<SdkTransferSession>).error.code,
        isIn(<NetworkErrorCode>[
          NetworkErrorCode.ioError,
          NetworkErrorCode.invalidArgument,
        ]),
      );

      final file = File('${directory.path}/payload.bin')
        ..writeAsStringSync('x');
      final untrustedResult = await fixture.coordinator.sendFile(
        _device('peer-a'),
        file.path,
      );
      expect(untrustedResult, isA<SdkFailure<SdkTransferSession>>());
      expect(
        (untrustedResult as SdkFailure<SdkTransferSession>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(fixture.facade.connectCalls, 0);
      expect(fixture.facade.transferCalls, 0);
    },
  );

  test(
    'capability failure invalidates the dynamic endpoint and never falls back to HTTP upload',
    () async {
      final fixture = await _Fixture.create(trusted: true);
      addTearDown(fixture.dispose);
      final directory = await Directory.systemTemp.createTemp('lan-v2-source-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.bin')
        ..writeAsStringSync('x');

      final result = await fixture.coordinator.sendFile(
        _device('peer-a'),
        file.path,
      );

      expect(result, isA<SdkFailure<SdkTransferSession>>());
      expect(fixture.invalidatedPeerIds, <String>['peer-a']);
      expect(fixture.updatedEndpoints, isEmpty);
      expect(fixture.facade.connectCalls, 0);
      expect(fixture.facade.transferCalls, 0);
    },
  );

  test(
    'incoming decisions are one-shot and duplicate decisions do not repeat native response',
    () async {
      final fixture = await _Fixture.create(trusted: true);
      addTearDown(fixture.dispose);
      final offer = _offer('transfer-a', 'peer-a');
      final incoming = fixture.coordinator.incomingOffers.first;
      fixture.facade.emit(offer);
      expect(await incoming, same(offer));

      final accepted = await fixture.coordinator.accept(offer);
      expect(accepted, isA<SdkSuccess<void>>());
      expect(fixture.facade.responses, <(String, bool)>[('transfer-a', true)]);

      final duplicate = await fixture.coordinator.accept(offer);
      expect(duplicate, isA<SdkSuccess<void>>());
      expect(fixture.facade.responses, <(String, bool)>[('transfer-a', true)]);

      final conflicting = await fixture.coordinator.reject(offer);
      expect(conflicting, isA<SdkFailure<void>>());
      expect(
        (conflicting as SdkFailure<void>).error.code,
        NetworkErrorCode.invalidArgument,
      );
      expect(fixture.facade.responses, <(String, bool)>[('transfer-a', true)]);
    },
  );

  test(
    'native accept failure keeps offer pending and allows subsequent retry',
    () async {
      final fixture = await _Fixture.create(trusted: true);
      addTearDown(fixture.dispose);
      final offer = _offer('transfer-a', 'peer-a');
      fixture.facade.emit(offer);

      fixture.facade.failRespond = true;
      final failedAccept = await fixture.coordinator.accept(offer);
      expect(failedAccept, isA<SdkFailure<void>>());
      expect(fixture.facade.responses, <(String, bool)>[('transfer-a', true)]);

      // Second accept must invoke native again since previous failed
      fixture.facade.failRespond = false;
      final secondAccept = await fixture.coordinator.accept(offer);
      expect(secondAccept, isA<SdkSuccess<void>>());
      expect(fixture.facade.responses, <(String, bool)>[
        ('transfer-a', true),
        ('transfer-a', true),
      ]);
    },
  );

  test('native reject failure keeps offer pending and allows retry', () async {
    final fixture = await _Fixture.create(trusted: true);
    addTearDown(fixture.dispose);
    final offer = _offer('transfer-a', 'peer-a');
    fixture.facade.emit(offer);

    fixture.facade.failRespond = true;
    final failedReject = await fixture.coordinator.reject(offer);
    expect(failedReject, isA<SdkFailure<void>>());

    fixture.facade.failRespond = false;
    final secondReject = await fixture.coordinator.reject(offer);
    expect(secondReject, isA<SdkSuccess<void>>());
    expect(fixture.facade.responses, <(String, bool)>[
      ('transfer-a', false),
      ('transfer-a', false),
    ]);
  });

  test(
    'two concurrent accepts reuse the same in-flight operation and call native once',
    () async {
      final fixture = await _Fixture.create(trusted: true);
      addTearDown(fixture.dispose);
      final offer = _offer('transfer-a', 'peer-a');
      fixture.facade.emit(offer);

      final completer = Completer<void>();
      fixture.facade.respondCompleter = completer;

      final future1 = fixture.coordinator.accept(offer);
      final future2 = fixture.coordinator.accept(offer);

      completer.complete();
      final results = await Future.wait([future1, future2]);

      expect(results[0], isA<SdkSuccess<void>>());
      expect(results[1], isA<SdkSuccess<void>>());
      expect(fixture.facade.responses, <(String, bool)>[('transfer-a', true)]);
    },
  );

  test(
    'conflicting decision while accept is in flight returns invalidState error',
    () async {
      final fixture = await _Fixture.create(trusted: true);
      addTearDown(fixture.dispose);
      final offer = _offer('transfer-a', 'peer-a');
      fixture.facade.emit(offer);

      final completer = Completer<void>();
      fixture.facade.respondCompleter = completer;

      final acceptFuture = fixture.coordinator.accept(offer);
      final rejectResult = await fixture.coordinator.reject(offer);

      expect(rejectResult, isA<SdkFailure<void>>());
      expect(
        (rejectResult as SdkFailure<void>).error.code,
        NetworkErrorCode.invalidState,
      );

      completer.complete();
      expect(await acceptFuture, isA<SdkSuccess<void>>());
      expect(fixture.facade.responses, <(String, bool)>[('transfer-a', true)]);
    },
  );

  test(
    'unauthorized relay accept natively rejects and returns authenticationFailed',
    () async {
      final fixture = await _Fixture.create(trusted: true);
      addTearDown(fixture.dispose);
      // Relay offer for peer with relay=false (default trust)
      final offer = IncomingTransferOffer(
        eventId: 'event-transfer-r',
        timestamp: DateTime.utc(2026),
        transferId: 'transfer-r',
        peerId: 'peer-a',
        fileName: 'payload.bin',
        fileSize: 1,
        routeType: NetworkRouteType.relay,
      );
      fixture.facade.emit(offer);

      final result = await fixture.coordinator.accept(offer);
      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(fixture.facade.responses, <(String, bool)>[('transfer-r', false)]);
    },
  );

  test(
    'when accept is in flight and timeout timer fires, successful accept does not trigger duplicate reject',
    () async {
      final fixture = await _Fixture.create(
        trusted: true,
        offerTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(fixture.dispose);
      final offer = _offer('transfer-timeout-success', 'peer-a');
      fixture.facade.emit(offer);

      final completer = Completer<void>();
      fixture.facade.respondCompleter = completer;

      final acceptFuture = fixture.coordinator.accept(offer);

      // Wait until the 30ms offerTimeout timer fires and enters _expireOffer,
      // which will await the in-flight acceptFuture
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Complete native response successfully
      completer.complete();
      final acceptResult = await acceptFuture;
      expect(acceptResult, isA<SdkSuccess<void>>());

      // Give event loop time to run _expireOffer completion
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Assert coordinator committed the accept and did not send a reject
      expect(fixture.facade.responses, <(String, bool)>[
        ('transfer-timeout-success', true),
      ]);
    },
  );

  test(
    'when accept is in flight and timeout timer fires, failed accept causes timeout handler to send reject',
    () async {
      final fixture = await _Fixture.create(
        trusted: true,
        offerTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(fixture.dispose);
      final offer = _offer('transfer-timeout-fail', 'peer-a');
      fixture.facade.emit(offer);

      final completer = Completer<void>();
      fixture.facade.respondCompleter = completer;
      fixture.facade.failRespondCount =
          1; // Fail first response (in-flight accept), allow subsequent fallback reject

      final acceptFuture = fixture.coordinator.accept(offer);

      // Wait until timer fires and waits on in-flight accept
      await Future<void>.delayed(const Duration(milliseconds: 60));

      completer.complete();
      final acceptResult = await acceptFuture;
      expect(acceptResult, isA<SdkFailure<void>>());

      // Give event loop time to run _expireOffer fallback reject
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fixture.facade.responses, <(String, bool)>[
        ('transfer-timeout-fail', true),
        ('transfer-timeout-fail', false),
      ]);
    },
  );

  test(
    'setRelayAuthorization callback throws returns NetworkFailure',
    () async {
      final store = LanPeerTrustStore();
      await store.save(_trust('peer-a'));
      final facade = _RecordingFacade();
      final transferService = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
          peerTrustStore: store,
        ),
        storageService: LanStorageService(),
      );
      final coordinator = LanNativeTransferCoordinator(
        transferService: transferService,
        networkFacade: facade,
        trustStore: store,
        updateDirectEndpoint: (deviceId, endpoint) async =>
            const SdkSuccess<void>(null),
        invalidateDirectEndpoint: (deviceId) async =>
            const SdkSuccess<void>(null),
        setRelayAuthorization: (peerId, enabled) async {
          throw Exception('Simulated setRelayAuthorization callback throw');
        },
      );
      addTearDown(() async {
        await coordinator.dispose();
        transferService.dispose();
        await store.dispose();
        await facade.close();
      });

      final result = await coordinator.setRelayAuthorization(
        peerId: 'peer-a',
        enabled: true,
      );

      expect(result, isA<SdkFailure<void>>());
      final failure = result as SdkFailure<void>;
      expect(failure.error.operation, NetworkOperation.upsertPeer);
      expect(failure.error.peerId, 'peer-a');
    },
  );

  test('removeTrustedPeer callback throws returns NetworkFailure', () async {
    final store = LanPeerTrustStore();
    await store.save(_trust('peer-a'));
    final facade = _RecordingFacade();
    final transferService = LanTransferService(
      currentDeviceId: 'device-a',
      securityService: LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      ),
      storageService: LanStorageService(),
    );
    final coordinator = LanNativeTransferCoordinator(
      transferService: transferService,
      networkFacade: facade,
      trustStore: store,
      updateDirectEndpoint: (deviceId, endpoint) async =>
          const SdkSuccess<void>(null),
      invalidateDirectEndpoint: (deviceId) async =>
          const SdkSuccess<void>(null),
      removeTrust: (deviceId) async {
        throw Exception('Simulated removeTrust callback throw');
      },
    );
    addTearDown(() async {
      await coordinator.dispose();
      transferService.dispose();
      await store.dispose();
      await facade.close();
    });

    final result = await coordinator.removeTrustedPeer('peer-a');

    expect(result, isA<SdkFailure<void>>());
    final failure = result as SdkFailure<void>;
    expect(failure.error.operation, NetworkOperation.removePeer);
    expect(failure.error.peerId, 'peer-a');
  });
}

final class _Fixture {
  _Fixture._({
    required this.store,
    required this.facade,
    required this.transferService,
    required this.coordinator,
    required this.updatedEndpoints,
    required this.invalidatedPeerIds,
  });

  final LanPeerTrustStore store;
  final _RecordingFacade facade;
  final LanTransferService transferService;
  final LanNativeTransferCoordinator coordinator;
  final List<String> updatedEndpoints;
  final List<String> invalidatedPeerIds;

  static Future<_Fixture> create({
    bool trusted = false,
    Duration offerTimeout = const Duration(seconds: 25),
  }) async {
    final store = LanPeerTrustStore();
    if (trusted) await store.save(_trust('peer-a'));
    final facade = _RecordingFacade();
    final transferService = LanTransferService(
      currentDeviceId: 'device-a',
      securityService: LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      ),
      storageService: LanStorageService(),
    );
    final updatedEndpoints = <String>[];
    final invalidatedPeerIds = <String>[];
    final coordinator = LanNativeTransferCoordinator(
      transferService: transferService,
      networkFacade: facade,
      trustStore: store,
      updateDirectEndpoint: (deviceId, endpoint) async {
        updatedEndpoints.add('$deviceId:$endpoint');
        return const SdkSuccess<void>(null);
      },
      invalidateDirectEndpoint: (deviceId) async {
        invalidatedPeerIds.add(deviceId);
        return const SdkSuccess<void>(null);
      },
      offerTimeout: offerTimeout,
    );
    final fixture = _Fixture._(
      store: store,
      facade: facade,
      transferService: transferService,
      coordinator: coordinator,
      updatedEndpoints: updatedEndpoints,
      invalidatedPeerIds: invalidatedPeerIds,
    );
    return fixture;
  }

  Future<void> dispose() async {
    await coordinator.dispose();
    transferService.dispose();
    await store.dispose();
    await facade.close();
  }
}

final class _RecordingFacade extends Fake implements NetworkFacade {
  final StreamController<SdkEvent> _events =
      StreamController<SdkEvent>.broadcast();
  final List<(String, bool)> responses = <(String, bool)>[];
  int connectCalls = 0;
  int transferCalls = 0;
  bool failRespond = false;
  int? failRespondCount;
  Completer<void>? respondCompleter;

  @override
  Stream<SdkEvent> get events => _events.stream;

  void emit(SdkEvent event) => _events.add(event);

  @override
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    connectCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<SdkTransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  }) async {
    transferCalls++;
    return SdkSuccess(
      SdkTransferSession(
        transferId: transferId,
        peerId: peerId,
        filePath: filePath,
        routeType: NetworkRouteType.quicDirect,
      ),
    );
  }

  @override
  Future<SdkResult<void>> respondToIncomingTransfer({
    required String transferId,
    required bool accept,
  }) async {
    if (respondCompleter != null) {
      await respondCompleter!.future;
    }
    responses.add((transferId, accept));
    final count = failRespondCount;
    if (failRespond || (count != null && count > 0)) {
      if (count != null && count > 0) {
        failRespondCount = count - 1;
      }
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Simulated respondToIncomingTransfer failure.',
          operation: NetworkOperation.respondToIncoming,
        ),
      );
    }
    return const SdkSuccess<void>(null);
  }

  Future<void> close() => _events.close();
}

LanDiscoveredPeer _device(String id) => LanDiscoveredPeer(
  deviceId: id,
  alias: id,
  ip: '127.0.0.1',
  controlPort: 53317,
  deviceType: LanDeviceType.desktop,
  os: 'test',
  lastSeen: DateTime.utc(2026),
);

IncomingTransferOffer _offer(String transferId, String peerId) =>
    IncomingTransferOffer(
      eventId: 'event-$transferId',
      timestamp: DateTime.utc(2026),
      transferId: transferId,
      peerId: peerId,
      fileName: 'payload.bin',
      fileSize: 1,
      routeType: NetworkRouteType.quicDirect,
    );

LanPeerTrustRecord _trust(String deviceId) => LanPeerTrustRecord(
  deviceId: deviceId,
  certificateFingerprint:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  inboundAccessToken: 'inbound-$deviceId',
  outboundAccessToken: 'outbound-$deviceId',
  x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
  networkIdentityPublicKey: Uint8List.fromList(List<int>.filled(32, 2)),
  origin: PeerTrustOrigin.localPin,
  authorization: const PeerRouteAuthorization(localDirect: true, relay: false),
  createdAt: DateTime.utc(2026),
);
