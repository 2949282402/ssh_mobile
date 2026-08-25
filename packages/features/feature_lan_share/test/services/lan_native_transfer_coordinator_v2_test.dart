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

  static Future<_Fixture> create({bool trusted = false}) async {
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
    responses.add((transferId, accept));
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
