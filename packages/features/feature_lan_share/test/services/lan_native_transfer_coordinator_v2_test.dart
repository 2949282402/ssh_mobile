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
        peerId: 'peer-a',
        transferId: 'tx-1',
        filePath:
            '/tmp/does-not-exist-${DateTime.now().microsecondsSinceEpoch}',
        discovery: _device('peer-a'),
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
        peerId: 'peer-a',
        transferId: 'tx-dir',
        filePath: directory.path,
        discovery: _device('peer-a'),
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
        peerId: 'peer-a',
        transferId: 'tx-untrusted',
        filePath: file.path,
        discovery: _device('peer-a'),
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
    'capability failure invalidates the dynamic endpoint and falls back to relay if authorized',
    () async {
      final fixture = await _Fixture.create(trusted: true);
      addTearDown(fixture.dispose);
      final directory = await Directory.systemTemp.createTemp('lan-v2-source-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.bin')
        ..writeAsStringSync('x');

      final result = await fixture.coordinator.sendFile(
        peerId: 'peer-a',
        transferId: 'tx-cap-fail',
        filePath: file.path,
        discovery: _device('peer-a'),
      );

      expect(result, isA<SdkFailure<SdkTransferSession>>());
      expect(fixture.invalidatedPeerIds, <String>['peer-a']);
      expect(fixture.updatedEndpoints, isEmpty);
      expect(fixture.facade.connectCalls, 0);
      expect(fixture.facade.transferCalls, 0);
    },
  );

  test(
    'trusted offline peer with relay=true sends file via Relay directly',
    () async {
      final fixture = await _Fixture.create(
        trusted: true,
        relayAuthorized: true,
      );
      addTearDown(fixture.dispose);
      final directory = await Directory.systemTemp.createTemp('lan-v2-source-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.bin')
        ..writeAsStringSync('hello-relay');

      final result = await fixture.coordinator.sendFile(
        peerId: 'peer-a',
        transferId: 'tx-relay-offline',
        filePath: file.path,
        discovery: null, // Offline, no discovery candidate
      );

      expect(result, isA<SdkSuccess<SdkTransferSession>>());
      expect(fixture.facade.connectCalls, 1);
      expect(fixture.facade.transferCalls, 1);
      expect(fixture.invalidatedPeerIds, contains('peer-a'));
    },
  );

  test('trusted offline peer with relay=false returns noRoute', () async {
    final fixture = await _Fixture.create(
      trusted: true,
      relayAuthorized: false,
    );
    addTearDown(fixture.dispose);
    final directory = await Directory.systemTemp.createTemp('lan-v2-source-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/payload.bin')
      ..writeAsStringSync('hello-no-relay');

    final result = await fixture.coordinator.sendFile(
      peerId: 'peer-a',
      transferId: 'tx-no-route',
      filePath: file.path,
      discovery: null,
    );

    expect(result, isA<SdkFailure<SdkTransferSession>>());
    final failure = result as SdkFailure<SdkTransferSession>;
    expect(failure.error.code, NetworkErrorCode.noRoute);
    expect(fixture.facade.connectCalls, 0);
    expect(fixture.facade.transferCalls, 0);
  });

  test(
    'runtime-blocked incoming offer is rejected and never published to UI',
    () async {
      final fixture = await _Fixture.create(trusted: true);
      addTearDown(fixture.dispose);
      fixture.policyPort.blockedPeers.add('peer-a');

      final offer = _offer('transfer-blocked', 'peer-a');
      var offerEmitted = false;
      final sub = fixture.coordinator.incomingOffers.listen((_) {
        offerEmitted = true;
      });
      addTearDown(sub.cancel);

      fixture.facade.emit(offer);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(offerEmitted, isFalse);
      expect(fixture.facade.responses, contains(('transfer-blocked', false)));
    },
  );

  test(
    'insufficient disk space rejects incoming offer with resourceLimit',
    () async {
      final fixture = await _Fixture.create(
        trusted: true,
        freeDiskSpaceMb: 50.0, // Less than 100MB buffer
      );
      addTearDown(fixture.dispose);

      final offer = _offer(
        'transfer-large',
        'peer-a',
        fileSize: 1024 * 1024 * 100,
      );
      final incoming = fixture.coordinator.incomingOffers.first;
      fixture.facade.emit(offer);
      expect(await incoming, same(offer));

      final result = await fixture.coordinator.accept(offer);
      expect(result, isA<SdkFailure<void>>());
      final failure = result as SdkFailure<void>;
      expect(failure.error.code, NetworkErrorCode.resourceLimit);
      expect(fixture.facade.responses, contains(('transfer-large', false)));
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
      final incoming = fixture.coordinator.incomingOffers.first;
      fixture.facade.emit(offer);
      expect(await incoming, same(offer));

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
    final incoming = fixture.coordinator.incomingOffers.first;
    fixture.facade.emit(offer);
    expect(await incoming, same(offer));

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
      final incoming = fixture.coordinator.incomingOffers.first;
      fixture.facade.emit(offer);
      expect(await incoming, same(offer));

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
      final incoming = fixture.coordinator.incomingOffers.first;
      fixture.facade.emit(offer);
      expect(await incoming, same(offer));

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
      final offer = IncomingTransferOffer(
        eventId: 'ev-relay',
        timestamp: DateTime.now(),
        transferId: 'tx-relay',
        peerId: 'peer-a',
        fileName: 'file.bin',
        fileSize: 10,
        routeType: NetworkRouteType.relay,
      );

      final result = await fixture.coordinator.accept(offer);
      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(fixture.facade.responses, contains(('tx-relay', false)));
    },
  );

  test(
    'offer timeout rejects automatically after deadline if no decision made',
    () async {
      final fixture = await _Fixture.create(
        trusted: true,
        offerTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(fixture.dispose);
      final offer = _offer('transfer-timeout', 'peer-a');
      final incoming = fixture.coordinator.incomingOffers.first;
      fixture.facade.emit(offer);
      expect(await incoming, same(offer));

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(fixture.facade.responses, contains(('transfer-timeout', false)));
    },
  );

  test(
    'accept in-flight timeout race: successful accept completes and cancels timeout reject',
    () async {
      final fixture = await _Fixture.create(
        trusted: true,
        offerTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(fixture.dispose);
      final offer = _offer('transfer-race-win', 'peer-a');
      final incoming = fixture.coordinator.incomingOffers.first;
      fixture.facade.emit(offer);
      expect(await incoming, same(offer));

      final completer = Completer<void>();
      fixture.facade.respondCompleter = completer;

      final acceptFuture = fixture.coordinator.accept(offer);

      await Future<void>.delayed(const Duration(milliseconds: 80));

      completer.complete();
      final result = await acceptFuture;
      expect(result, isA<SdkSuccess<void>>());

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fixture.facade.responses, <(String, bool)>[
        ('transfer-race-win', true),
      ]);
    },
  );

  test('setRelayAuthorization delegates to policyPort', () async {
    final fixture = await _Fixture.create(trusted: true);
    addTearDown(fixture.dispose);

    final result = await fixture.coordinator.setRelayAuthorization(
      peerId: 'peer-a',
      enabled: true,
    );
    expect(result, isA<SdkSuccess<void>>());
    expect((await fixture.store.read('peer-a'))?.authorization.relay, isTrue);
  });

  test('removeTrustedPeer delegates to policyPort', () async {
    final fixture = await _Fixture.create(trusted: true);
    addTearDown(fixture.dispose);

    final result = await fixture.coordinator.removeTrustedPeer('peer-a');
    expect(result, isA<SdkSuccess<void>>());
    expect(await fixture.store.read('peer-a'), isNull);
  });
}

final class _Fixture {
  _Fixture._({
    required this.store,
    required this.facade,
    required this.transferService,
    required this.policyPort,
    required this.coordinator,
    required this.updatedEndpoints,
    required this.invalidatedPeerIds,
  });

  final LanPeerTrustStore store;
  final _RecordingFacade facade;
  final LanTransferService transferService;
  final _RecordingPolicyPort policyPort;
  final LanNativeTransferCoordinator coordinator;
  final List<String> updatedEndpoints;
  final List<String> invalidatedPeerIds;

  static Future<_Fixture> create({
    bool trusted = false,
    bool relayAuthorized = false,
    Duration offerTimeout = const Duration(seconds: 25),
    double freeDiskSpaceMb = 1000.0,
  }) async {
    final store = LanPeerTrustStore();
    if (trusted) {
      await store.save(
        _trust('peer-a').copyWith(
          authorization: PeerRouteAuthorization(
            localDirect: true,
            relay: relayAuthorized,
          ),
        ),
      );
    }
    final facade = _RecordingFacade();
    final transferService = LanTransferService(
      currentDeviceId: 'device-a',
      securityService: LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      ),
      storageService: LanStorageService(
        freeDiskSpaceMbProvider: () async => freeDiskSpaceMb,
      ),
    );
    final updatedEndpoints = <String>[];
    final invalidatedPeerIds = <String>[];
    final policyPort = _RecordingPolicyPort(
      store: store,
      facade: facade,
      updatedEndpoints: updatedEndpoints,
      invalidatedPeerIds: invalidatedPeerIds,
    );
    final coordinator = LanNativeTransferCoordinator(
      transferService: transferService,
      networkFacade: facade,
      policyPort: policyPort,
      storageService: LanStorageService(
        freeDiskSpaceMbProvider: () async => freeDiskSpaceMb,
      ),
      offerTimeout: offerTimeout,
    );
    final fixture = _Fixture._(
      store: store,
      facade: facade,
      transferService: transferService,
      policyPort: policyPort,
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

final class _RecordingPolicyPort implements LanNativePeerPolicyPort {
  _RecordingPolicyPort({
    required this.store,
    required this.facade,
    this.updatedEndpoints,
    this.invalidatedPeerIds,
  });

  final LanPeerTrustStore store;
  final NetworkFacade facade;
  final List<String>? updatedEndpoints;
  final List<String>? invalidatedPeerIds;
  final Set<String> blockedPeers = {};

  @override
  Future<NetworkResult<LanPeerPolicySnapshot>> getPeerPolicy(
    String peerId,
  ) async {
    final t = await store.read(peerId);
    final isBlocked = blockedPeers.contains(peerId);
    return NetworkSuccess(
      LanPeerPolicySnapshot(
        trust: t,
        runtimeBlocked: isBlocked,
        revoked: false,
      ),
    );
  }

  @override
  Future<NetworkResult<void>> updateDirectEndpoint(
    String peerId,
    String endpoint,
  ) async {
    updatedEndpoints?.add('$peerId:$endpoint');
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> invalidateDirectEndpoint(String peerId) async {
    invalidatedPeerIds?.add(peerId);
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> setRelayAuthorization(
    String peerId,
    bool enabled,
  ) async {
    await store.setRelayAuthorization(peerId, enabled);
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> removeTrust(String peerId) async {
    await store.delete(peerId);
    return const NetworkSuccess(null);
  }

  @override
  Future<NetworkResult<void>> reconcilePersistedTrust(
    LanPeerTrustRecord record,
  ) async {
    return const NetworkSuccess(null);
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

IncomingTransferOffer _offer(
  String transferId,
  String peerId, {
  int fileSize = 100,
}) => IncomingTransferOffer(
  eventId: 'event-$transferId',
  timestamp: DateTime.now(),
  transferId: transferId,
  peerId: peerId,
  fileName: 'test.bin',
  fileSize: fileSize,
  routeType: NetworkRouteType.quicDirect,
);

LanPeerTrustRecord _trust(String id) => LanPeerTrustRecord(
  deviceId: id,
  certificateFingerprint:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  inboundAccessToken: 'inbound',
  outboundAccessToken: 'outbound',
  x25519PublicKey: Uint8List(32),
  networkIdentityPublicKey: Uint8List(32),
  origin: PeerTrustOrigin.localPin,
  authorization: const PeerRouteAuthorization(localDirect: true, relay: false),
  createdAt: DateTime.utc(2026),
);
