import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    HttpOverrides.global = null;
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  group('LAN Network V2 Final Acceptance Matrix', () {
    test(
      'B. Offline Relay: trusted offline peer sends binary via Relay and fails with noRoute when relay=false',
      () async {
        final store = LanPeerTrustStore();
        addTearDown(store.dispose);

        // Case 1: relay=true -> sends successfully
        await store.save(_record('peer-relay', relay: true));
        final facade = _MockAcceptanceFacade();
        final registry = LanNativePeerRegistry(
          trustStore: store,
          networkFacade: facade,
        );
        final coordinator = LanNativeTransferCoordinator(
          transferService: _dummyTransferService(store),
          networkFacade: facade,
          policyPort: registry,
          storageService: LanStorageService(
            freeDiskSpaceMbProvider: () async => 1000.0,
          ),
        );
        addTearDown(coordinator.dispose);

        final tempDir = await Directory.systemTemp.createTemp('lan-accept-b-');
        addTearDown(() => tempDir.delete(recursive: true));
        final testFile = File('${tempDir.path}/photo.jpg')
          ..writeAsStringSync('dummy-image');

        final relayResult = await coordinator.sendFile(
          peerId: 'peer-relay',
          transferId: 'tx-relay-1',
          filePath: testFile.path,
          discovery: null,
        );
        expect(relayResult, isA<NetworkSuccess<TransferSession>>());
        expect(facade.connectCalls, 1);
        expect(facade.transferCalls, 1);

        // Case 2: relay=false -> returns noRoute without attempting connect
        await store.save(_record('peer-no-relay', relay: false));
        facade.connectCalls = 0;
        facade.transferCalls = 0;

        final noRelayResult = await coordinator.sendFile(
          peerId: 'peer-no-relay',
          transferId: 'tx-no-relay-1',
          filePath: testFile.path,
          discovery: null,
        );
        expect(noRelayResult, isA<NetworkFailure<TransferSession>>());
        final failure = noRelayResult as NetworkFailure<TransferSession>;
        expect(failure.error.code, NetworkErrorCode.noRoute);
        expect(facade.connectCalls, 0);
        expect(facade.transferCalls, 0);
      },
    );

    test(
      'C. Direct -> Relay fallback: direct connect failure retries once with Relay when relay=true',
      () async {
        HttpOverrides.global = _CapabilitiesHttpOverrides(
          getNativePort: () => 43123,
          expectedIdentityKey: Uint8List(32),
          expectedX25519Key: Uint8List(32),
        );

        final store = LanPeerTrustStore();
        addTearDown(store.dispose);
        await store.save(_record('peer-fallback', relay: true));

        final facade = _MockAcceptanceFacade();
        facade.failConnectCount = 1; // First direct connect fails
        final registry = LanNativePeerRegistry(
          trustStore: store,
          networkFacade: facade,
        );
        final coordinator = LanNativeTransferCoordinator(
          transferService: _dummyTransferService(store),
          networkFacade: facade,
          policyPort: registry,
          storageService: LanStorageService(
            freeDiskSpaceMbProvider: () async => 1000.0,
          ),
        );
        addTearDown(coordinator.dispose);

        final tempDir = await Directory.systemTemp.createTemp('lan-accept-c-');
        addTearDown(() => tempDir.delete(recursive: true));
        final testFile = File('${tempDir.path}/doc.pdf')
          ..writeAsStringSync('pdf-bytes');

        // Provide discovery to initiate direct connection
        final dev = _discoveredDevice('peer-fallback');
        final result = await coordinator.sendFile(
          peerId: 'peer-fallback',
          transferId: 'tx-fallback',
          filePath: testFile.path,
          discovery: dev,
        );

        expect(result, isA<NetworkSuccess<TransferSession>>());
        // Call 1 was direct connect (failed), call 2 was retry via Relay (succeeded)
        expect(facade.connectCalls, 2);
        expect(facade.transferCalls, 1);
      },
    );

    test(
      'D. Blocked incoming: runtimeBlocked peer offer is natively rejected before UI publication',
      () async {
        final store = LanPeerTrustStore();
        addTearDown(store.dispose);
        await store.save(_record('peer-blocked', relay: true));

        final facade = _MockAcceptanceFacade();
        final registry = LanNativePeerRegistry(
          trustStore: store,
          networkFacade: facade,
        );
        // Force native remove failure during revoke to trigger runtime-block
        facade.failRegister = true;
        facade.failRemove = true;
        await registry.revokeRelayForPeer('peer-blocked');
        expect(registry.isPeerBlocked('peer-blocked'), isTrue);

        final coordinator = LanNativeTransferCoordinator(
          transferService: _dummyTransferService(store),
          networkFacade: facade,
          policyPort: registry,
          storageService: LanStorageService(
            freeDiskSpaceMbProvider: () async => 1000.0,
          ),
        );
        addTearDown(coordinator.dispose);

        var uiReceivedOffer = false;
        final sub = coordinator.incomingOffers.listen((_) {
          uiReceivedOffer = true;
        });
        addTearDown(sub.cancel);

        final offer = IncomingTransferOffer(
          eventId: 'ev-blocked',
          timestamp: DateTime.now(),
          transferId: 'tx-blocked',
          peerId: 'peer-blocked',
          fileName: 'secret.zip',
          fileSize: 500,
          routeType: NetworkRouteType.relay,
        );
        facade.emit(offer);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(uiReceivedOffer, isFalse);
        expect(facade.responses, contains(('tx-blocked', false)));
      },
    );

    test(
      'E. Re-pair reconciliation: new pairing succeeds reconciliation and clears runtime-blocked status',
      () async {
        final store = LanPeerTrustStore();
        addTearDown(store.dispose);
        await store.save(_record('peer-repaired', relay: true));

        final facade = _MockAcceptanceFacade();
        final registry = LanNativePeerRegistry(
          trustStore: store,
          networkFacade: facade,
        );
        facade.failRegister = true;
        facade.failRemove = true;
        await registry.revokeRelayForPeer('peer-repaired');
        expect(registry.isPeerBlocked('peer-repaired'), isTrue);

        // New pairing updates store
        final newRecord = _record('peer-repaired', relay: true);
        await store.save(newRecord);

        // Native reconciliation still fails -> stays blocked
        final failedReconcile = await registry.reconcilePersistedTrust(
          newRecord,
        );
        expect(failedReconcile, isA<NetworkFailure<void>>());
        expect(registry.isPeerBlocked('peer-repaired'), isTrue);

        // Native registration succeeds -> clears blocked
        facade.failRegister = false;
        facade.failRemove = false;
        final successReconcile = await registry.reconcilePersistedTrust(
          newRecord,
        );
        expect(successReconcile, isA<NetworkSuccess<void>>());
        expect(registry.isPeerBlocked('peer-repaired'), isFalse);
      },
    );

    test(
      'F & G & H. History lifecycle and Neutral Inbox to LAN Sandbox file adoption',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'lan-sandbox-gc-',
        );
        addTearDown(() => tempRoot.delete(recursive: true));
        final nativeInbox = Directory('${tempRoot.path}/native_inbox')
          ..createSync();
        final lanSandbox = Directory('${tempRoot.path}/lan_sandbox')
          ..createSync();

        final storageService = LanStorageService(
          sandboxDirectoryProvider: () async => lanSandbox,
        );

        // 1. Simulate Native Inbox writing received file
        final nativeFile = File('${nativeInbox.path}/transfer_123.tmp')
          ..writeAsStringSync('transferred-content-bytes');
        expect(nativeFile.existsSync(), isTrue);

        // 2. Adopt into LAN Sandbox
        final adoptedFile = await storageService.adoptIncomingNetworkFile(
          nativePath: nativeFile.path,
          fileName: 'received_photo.jpg',
        );

        expect(adoptedFile.existsSync(), isTrue);
        expect(adoptedFile.path, startsWith(lanSandbox.path));
        expect(adoptedFile.readAsStringSync(), 'transferred-content-bytes');
        // Source in neutral inbox must be removed after adoption
        expect(nativeFile.existsSync(), isFalse);

        // 3. Recall / deleteSandboxFile removes adopted file
        final deleted = await storageService.deleteSandboxFile(
          adoptedFile.path,
        );
        expect(deleted, isTrue);
        expect(adoptedFile.existsSync(), isFalse);

        // 4. Garbage Collection test
        final expiredFile = File('${lanSandbox.path}/old_file.bin')
          ..writeAsStringSync('old');
        expect(expiredFile.existsSync(), isTrue);
        final gcDeletedCount = await storageService
            .perform7DayGarbageCollection(
              ttl: Duration.zero, // Expire immediately
            );
        expect(gcDeletedCount, greaterThanOrEqualTo(1));
        expect(expiredFile.existsSync(), isFalse);
      },
    );

    test(
      'K. Restore isolation: failure of one peer does not abort restoration of other peers',
      () async {
        final store = LanPeerTrustStore();
        addTearDown(store.dispose);

        await store.save(_record('peer-1'));
        await store.save(_record('peer-2'));
        await store.save(_record('peer-3'));

        final facade = _MockAcceptanceFacade();
        facade.failRegisterPeerIds.add('peer-2'); // Only peer-2 fails

        final registry = LanNativePeerRegistry(
          trustStore: store,
          networkFacade: facade,
        );

        final report = await registry.restoreAll();
        expect(
          report.restoredPeerIds,
          containsAll(<String>['peer-1', 'peer-3']),
        );
        expect(report.blockedPeerIds, <String>['peer-2']);
        expect(report.failures.containsKey('peer-2'), isTrue);
        expect(registry.isPeerBlocked('peer-2'), isTrue);
        expect(registry.isPeerBlocked('peer-1'), isFalse);
        expect(registry.isPeerBlocked('peer-3'), isFalse);
      },
    );

    test(
      'L. Cross-layer outgoing file transfer: ViewModel -> atomic history -> progress -> completed',
      () async {
        final store = LanPeerTrustStore();
        addTearDown(store.dispose);
        await store.save(_record('peer-out', relay: true));

        final database = LanShareDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.dispose);
        final historyDao = database.lanHistoryDao;

        final facade = _MockAcceptanceFacade();
        final registry = LanNativePeerRegistry(
          trustStore: store,
          networkFacade: facade,
        );

        final tempDir = await Directory.systemTemp.createTemp(
          'lan-accept-out-',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final testFile = File('${tempDir.path}/vacation.jpg')
          ..writeAsStringSync('jpeg-image-binary-data');

        final storageService = LanStorageService(
          sandboxDirectoryProvider: () async => tempDir,
          freeDiskSpaceBytesProvider: () async => 1024 * 1024 * 1024,
        );

        final transferService = LanTransferService(
          currentDeviceId: 'device-self',
          securityService: LanSecurityService(
            appOwnedX25519PrivateSeed: Uint8List(32),
            peerTrustStore: store,
          ),
          storageService: storageService,
        );
        addTearDown(transferService.dispose);

        final coordinator = LanNativeTransferCoordinator(
          transferService: transferService,
          networkFacade: facade,
          policyPort: registry,
          storageService: storageService,
        );
        addTearDown(coordinator.dispose);

        final settings = FakeLanShareSettings();
        addTearDown(settings.dispose);

        final viewModel = LanShareViewModel(
          discoveryService: FakeLanDiscoveryService(),
          securityService: transferService.securityService,
          storageService: storageService,
          transferService: transferService,
          nativeTransferCoordinator: coordinator,
          historyDao: historyDao,
          appSettings: settings,
          dataProtection: FakeLanShareDataProtection(),
          logger: FakeLanShareLogger(),
          ownsRuntime: false,
        );
        await viewModel.initialize();
        addTearDown(viewModel.dispose);

        // 1. ViewModel sends file
        final result = await viewModel.sendFile(
          peerId: 'peer-out',
          filePath: testFile.path,
        );

        expect(result, isA<NetworkSuccess<TransferSession>>());
        final session = (result as NetworkSuccess<TransferSession>).data;
        expect(session.transferId, isNotEmpty);

        // Verify history record was inserted before network transfer
        var record = await historyDao.getRecord(session.transferId);
        expect(record, isNotNull);
        expect(record!.id, session.transferId);
        expect(record.isIncoming, isFalse);
        expect(record.payloadType, 'image');
        expect(record.status, LanTransferStatus.transferring.toJson());

        // 2. Native emits progress
        facade.emit(
          TransferProgress(
            eventId: 'ev-prog-1',
            timestamp: DateTime.now(),
            transferId: session.transferId,
            bytesTransferred: 10,
            totalBytes: testFile.lengthSync(),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        record = await historyDao.getRecord(session.transferId);
        expect(record!.bytesTransferred, 10);

        // 3. Native emits completed
        facade.emit(
          TransferCompleted(
            eventId: 'ev-comp-1',
            timestamp: DateTime.now(),
            transferId: session.transferId,
            localPath: testFile.path,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        record = await historyDao.getRecord(session.transferId);
        expect(record!.status, LanTransferStatus.completed.toJson());
      },
    );

    test(
      'M. Cross-layer incoming file transfer: Offer -> classified history -> native download -> sandbox adoption -> completed',
      () async {
        final store = LanPeerTrustStore();
        addTearDown(store.dispose);
        await store.save(_record('peer-in', relay: true));

        final database = LanShareDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.dispose);
        final historyDao = database.lanHistoryDao;

        final tempDir = await Directory.systemTemp.createTemp('lan-accept-in-');
        addTearDown(() => tempDir.delete(recursive: true));
        final sandboxDir = Directory('${tempDir.path}/sandbox')..createSync();
        final nativeInboxDir = Directory('${tempDir.path}/inbox')..createSync();

        final storageService = LanStorageService(
          sandboxDirectoryProvider: () async => sandboxDir,
          freeDiskSpaceBytesProvider: () async => 1024 * 1024 * 1024,
        );

        final facade = _MockAcceptanceFacade();
        final registry = LanNativePeerRegistry(
          trustStore: store,
          networkFacade: facade,
        );

        final transferService = LanTransferService(
          currentDeviceId: 'device-self',
          securityService: LanSecurityService(
            appOwnedX25519PrivateSeed: Uint8List(32),
            peerTrustStore: store,
          ),
          storageService: storageService,
        );
        addTearDown(transferService.dispose);

        final coordinator = LanNativeTransferCoordinator(
          transferService: transferService,
          networkFacade: facade,
          policyPort: registry,
          storageService: storageService,
        );
        addTearDown(coordinator.dispose);

        final settings = FakeLanShareSettings();
        addTearDown(settings.dispose);

        final receiver = LanReceiverCoordinator(
          appSettings: settings,
          logger: FakeLanShareLogger(),
          dataProtection: FakeLanShareDataProtection(),
          networkIdentity: FakeLanShareIdentity(),
          networkFactory: FakeLanShareNetworkFactory(networkFacade: facade),
          bootstrapClient: FakeLanShareBootstrapClient(),
          historyRepository: LanShareHistoryRepository(database),
          networkRuntime: FakeLanShareNetworkRuntime(),
          peerTrustStore: store,
          transferServiceOverride: transferService,
          discoveryServiceOverride: FakeLanDiscoveryService(),
          storageServiceOverride: storageService,
        );
        await receiver.ensureInitialized();
        addTearDown(receiver.close);

        final viewModel = await receiver.ensureViewModel();
        await viewModel.initialize();

        // 1. Native emits IncomingTransferOffer with image
        final offer = IncomingTransferOffer(
          eventId: 'ev-offer-in',
          timestamp: DateTime.now(),
          transferId: 'tx-incoming-photo',
          peerId: 'peer-in',
          fileName: 'landscape.jpg',
          fileSize: 2048,
          routeType: NetworkRouteType.quicDirect,
        );

        // 2. User accepts the incoming offer
        final acceptResult = await receiver.acceptNativeIncomingTransfer(offer);
        expect(acceptResult, isA<NetworkSuccess<void>>());
        expect(facade.responses, contains(('tx-incoming-photo', true)));

        // Verify history record created with classified payloadType: image
        await Future<void>.delayed(const Duration(milliseconds: 50));
        var record = await historyDao.getRecord('tx-incoming-photo');
        expect(record, isNotNull);
        expect(record!.payloadType, 'image');
        expect(record.isIncoming, isTrue);

        // 3. Native inbox downloads file
        final inboxFile = File('${nativeInboxDir.path}/download_tmp.bin')
          ..writeAsStringSync('jpeg-file-content');

        // 4. Native emits TransferCompleted
        facade.emit(
          TransferCompleted(
            eventId: 'ev-comp-in',
            timestamp: DateTime.now(),
            transferId: 'tx-incoming-photo',
            localPath: inboxFile.path,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // 5. Verify file was adopted into LAN sandbox cache and history updated
        record = await historyDao.getRecord('tx-incoming-photo');
        expect(record!.status, LanTransferStatus.completed.toJson());
        expect(record.localPath, isNotNull);
        expect(record.localPath!, startsWith(sandboxDir.path));

        final adoptedFile = File(record.localPath!);
        expect(adoptedFile.existsSync(), isTrue);
        expect(adoptedFile.readAsStringSync(), 'jpeg-file-content');
        // Source in native inbox must be deleted
        expect(inboxFile.existsSync(), isFalse);
      },
    );
  });
}

class _CapabilitiesHttpOverrides extends HttpOverrides {
  _CapabilitiesHttpOverrides({
    required this.getNativePort,
    required this.expectedIdentityKey,
    required this.expectedX25519Key,
  });

  final int Function() getNativePort;
  final Uint8List expectedIdentityKey;
  final Uint8List expectedX25519Key;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _MockCapabilitiesHttpClient(
      getNativePort: getNativePort,
      expectedIdentityKey: expectedIdentityKey,
      expectedX25519Key: expectedX25519Key,
    );
  }
}

class _MockCapabilitiesHttpClient extends Fake implements HttpClient {
  _MockCapabilitiesHttpClient({
    required this.getNativePort,
    required this.expectedIdentityKey,
    required this.expectedX25519Key,
  });

  final int Function() getNativePort;
  final Uint8List expectedIdentityKey;
  final Uint8List expectedX25519Key;

  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  bool Function(X509Certificate, String, int)? badCertificateCallback;
  @override
  String Function(Uri)? findProxy;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return _MockCapabilitiesRequest(
      nativePort: getNativePort(),
      expectedIdentityKey: expectedIdentityKey,
      expectedX25519Key: expectedX25519Key,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MockCapabilitiesRequest extends Fake implements HttpClientRequest {
  _MockCapabilitiesRequest({
    required this.nativePort,
    required this.expectedIdentityKey,
    required this.expectedX25519Key,
  });

  final int nativePort;
  final Uint8List expectedIdentityKey;
  final Uint8List expectedX25519Key;
  final _MockHttpHeaders _headers = _MockHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  bool followRedirects = false;

  @override
  Future<HttpClientResponse> close() async {
    final body = jsonEncode({
      'protocolVersion': LanControlProtocol.version,
      'e2eEncryption': true,
      'quicFileTransfer': true,
      'x25519PubKey': base64.encode(expectedX25519Key),
      'networkIdentityPubKey': base64.encode(expectedIdentityKey),
      'quicPort': nativePort,
    });
    return _MockCapabilitiesResponse(body: body);
  }
}

class _MockCapabilitiesResponse extends StreamView<List<int>>
    with Fake
    implements HttpClientResponse {
  _MockCapabilitiesResponse({required this.body})
    : super(Stream<List<int>>.value(utf8.encode(body)));

  final String body;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => utf8.encode(body).length;

  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
}

class _MockHttpHeaders extends Fake implements HttpHeaders {
  final Map<String, String> _map = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _map[name.toLowerCase()];
}

LanPeerTrustRecord _record(String id, {bool relay = false}) =>
    LanPeerTrustRecord(
      deviceId: id,
      certificateFingerprint:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      inboundAccessToken: 'inbound',
      outboundAccessToken: 'outbound',
      x25519PublicKey: Uint8List(32),
      networkIdentityPublicKey: Uint8List(32),
      origin: PeerTrustOrigin.localPin,
      authorization: PeerRouteAuthorization(localDirect: true, relay: relay),
      createdAt: DateTime.utc(2026),
    );

LanDiscoveredPeer _discoveredDevice(String id) => LanDiscoveredPeer(
  deviceId: id,
  alias: id,
  ip: '127.0.0.1',
  controlPort: 53317,
  advertisedNativePort: 43123,
  deviceType: LanDeviceType.desktop,
  os: 'test',
  lastSeen: DateTime.utc(2026),
);

LanTransferService _dummyTransferService(LanPeerTrustStore store) =>
    LanTransferService(
      currentDeviceId: 'device-self',
      securityService: LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      ),
      storageService: LanStorageService(),
    );

final class _MockAcceptanceFacade extends Fake implements NetworkFacade {
  final StreamController<SdkEvent> _events =
      StreamController<SdkEvent>.broadcast();
  final List<(String, bool)> responses = <(String, bool)>[];
  final Set<String> failRegisterPeerIds = <String>{};
  int connectCalls = 0;
  int transferCalls = 0;
  int failConnectCount = 0;
  bool failRegister = false;
  bool failRemove = false;

  @override
  Stream<SdkEvent> get events => _events.stream;

  void emit(SdkEvent event) => _events.add(event);

  @override
  Future<SdkResult<void>> registerPeer(PeerConfig config) async {
    if (failRegister || failRegisterPeerIds.contains(config.peerId)) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Register peer failed',
          operation: NetworkOperation.upsertPeer,
          peerId: config.peerId,
        ),
      );
    }
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> removePeer(String peerId) async {
    if (failRemove) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Remove peer failed',
          operation: NetworkOperation.removePeer,
          peerId: peerId,
        ),
      );
    }
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> disconnectPeer(String peerId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    connectCalls++;
    if (failConnectCount > 0) {
      failConnectCount--;
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'Direct connection failed',
          operation: NetworkOperation.connect,
          peerId: peerId,
        ),
      );
    }
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
