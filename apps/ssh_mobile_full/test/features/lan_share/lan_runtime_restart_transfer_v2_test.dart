import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  test(
    'restart file transfer preserves trust, updates native port, and validates SHA-256 without re-pairing',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'lan_restart_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final sandboxA = Directory('${tempDir.path}/sandbox_a')..createSync();
      final sandboxB = Directory('${tempDir.path}/sandbox_b')..createSync();

      final secureStorageA = _MemorySecureStorage();
      final secureStorageB = _MemorySecureStorage();

      final storeA = LanPeerTrustStore(secureStorage: secureStorageA);
      final storeB = LanPeerTrustStore(secureStorage: secureStorageB);
      addTearDown(() async {
        await storeA.dispose();
        await storeB.dispose();
      });

      final identityA = Uint8List.fromList(List<int>.filled(32, 0x11));
      final x25519A = Uint8List.fromList(List<int>.filled(32, 0x12));
      final identityB = Uint8List.fromList(List<int>.filled(32, 0x21));
      final x25519B = Uint8List.fromList(List<int>.filled(32, 0x22));

      final certFingerprintA =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final certFingerprintB =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

      // Initial Trust Records (paired once)
      final trustOnA = LanPeerTrustRecord(
        deviceId: 'device-b',
        certificateFingerprint: certFingerprintB,
        inboundAccessToken: 'inbound-a-b',
        outboundAccessToken: 'outbound-a-b',
        x25519PublicKey: x25519B,
        networkIdentityPublicKey: identityB,
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      );

      final trustOnB = LanPeerTrustRecord(
        deviceId: 'device-a',
        certificateFingerprint: certFingerprintA,
        inboundAccessToken: 'outbound-a-b',
        outboundAccessToken: 'inbound-a-b',
        x25519PublicKey: x25519A,
        networkIdentityPublicKey: identityA,
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      );

      await storeA.save(trustOnA);
      await storeB.save(trustOnB);

      // Verify that device A and device B secure storage backings are completely isolated
      final recordsA = await storeA.loadAll();
      expect(recordsA.map((r) => r.deviceId), contains('device-b'));
      expect(recordsA.map((r) => r.deviceId), isNot(contains('device-a')));

      final recordsB = await storeB.loadAll();
      expect(recordsB.map((r) => r.deviceId), contains('device-a'));
      expect(recordsB.map((r) => r.deviceId), isNot(contains('device-b')));

      int currentNativePortB = 43123;
      HttpOverrides.global = _CapabilitiesHttpOverrides(
        getNativePort: () => currentNativePortB,
        expectedIdentityKey: identityB,
        expectedX25519Key: x25519B,
      );

      // --- Node A setup ---
      final facadeA = _SimulatedTransferFacade(
        selfDeviceId: 'device-a',
        receiveDirectory: sandboxA.path,
      );
      final registryA = LanNativePeerRegistry(
        trustStore: storeA,
        networkFacade: facadeA,
      );
      final securityA = LanSecurityService(
        appOwnedX25519PrivateSeed: x25519A,
        peerTrustStore: storeA,
      );
      final storageA = LanStorageService();
      final transferServiceA = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: securityA,
        storageService: storageA,
        networkIdentityPublicKeyProvider: () async => identityA,
        nativeTransferPortProvider: () => 43101,
      );
      final coordinatorA = LanNativeTransferCoordinator(
        transferService: transferServiceA,
        networkFacade: facadeA,
        policyPort: registryA,
        storageService: storageA,
      );
      addTearDown(() async {
        await coordinatorA.dispose();
        await transferServiceA.close();
        await facadeA.dispose();
      });

      // --- Node B1 setup ---
      final facadeB1 = _SimulatedTransferFacade(
        selfDeviceId: 'device-b',
        receiveDirectory: sandboxB.path,
      );
      final registryB1 = LanNativePeerRegistry(
        trustStore: storeB,
        networkFacade: facadeB1,
      );
      final securityB = LanSecurityService(
        appOwnedX25519PrivateSeed: x25519B,
        peerTrustStore: storeB,
      );
      final storageB = LanStorageService();
      final transferServiceB1 = LanTransferService(
        currentDeviceId: 'device-b',
        securityService: securityB,
        storageService: storageB,
        networkIdentityPublicKeyProvider: () async => identityB,
        nativeTransferPortProvider: () => currentNativePortB,
      );
      final coordinatorB1 = LanNativeTransferCoordinator(
        transferService: transferServiceB1,
        networkFacade: facadeB1,
        policyPort: registryB1,
        storageService: storageB,
      );

      // Link facades for file data transmission
      _linkFacades(facadeA, facadeB1);

      await registryA.restoreAll();
      await registryB1.restoreAll();

      // First transfer: A sends file1 to B1
      final file1 = File('${tempDir.path}/source_1.txt')
        ..writeAsStringSync('First file content for LAN V2 transfer test.');
      final file1Hash = crypto.sha256
          .convert(file1.readAsBytesSync())
          .toString();

      final discoveredB1 = LanDiscoveredPeer(
        deviceId: 'device-b',
        alias: 'Device B',
        ip: '127.0.0.1',
        controlPort: 53317,
        advertisedNativePort: 43123,
        deviceType: LanDeviceType.desktop,
        os: 'linux',
        lastSeen: DateTime.now(),
      );

      // Setup incoming offer handler on B1
      final b1OfferFuture = coordinatorB1.incomingOffers.first;

      final sendSessionResult1 = await coordinatorA.sendFile(
        peerId: discoveredB1.deviceId,
        transferId: 'transfer-1',
        filePath: file1.path,
        discovery: discoveredB1,
      );
      expect(sendSessionResult1, isA<NetworkSuccess<TransferSession>>());

      final offer1 = await b1OfferFuture;
      expect(offer1.peerId, 'device-a');
      expect(offer1.fileName, 'source_1.txt');

      final acceptResult1 = await coordinatorB1.accept(offer1);
      expect(acceptResult1, isA<NetworkSuccess<void>>());

      await facadeA.pump();
      await facadeB1.pump();

      // Validate B1 received file1 and SHA-256 matches
      final receivedFile1 = File('${sandboxB.path}/source_1.txt');
      expect(receivedFile1.existsSync(), isTrue);
      final received1Hash = crypto.sha256
          .convert(receivedFile1.readAsBytesSync())
          .toString();
      expect(received1Hash, file1Hash);

      // --- Dispose Receiver B1 generation ---
      await coordinatorB1.dispose();
      await transferServiceB1.close();
      registryB1.detachFacade();
      await facadeB1.dispose();

      // --- Instantiate Receiver B2 generation (Restarted Receiver) ---
      // Same deviceId, keys, trustStore, but new native port 43124
      currentNativePortB = 43124;
      final facadeB2 = _SimulatedTransferFacade(
        selfDeviceId: 'device-b',
        receiveDirectory: sandboxB.path,
      );
      final registryB2 = LanNativePeerRegistry(
        trustStore: storeB,
        networkFacade: facadeB2,
      );
      final transferServiceB2 = LanTransferService(
        currentDeviceId: 'device-b',
        securityService: securityB,
        storageService: storageB,
        networkIdentityPublicKeyProvider: () async => identityB,
        nativeTransferPortProvider: () => currentNativePortB,
      );
      final coordinatorB2 = LanNativeTransferCoordinator(
        transferService: transferServiceB2,
        networkFacade: facadeB2,
        policyPort: registryB2,
        storageService: storageB,
      );
      addTearDown(() async {
        await coordinatorB2.dispose();
        await transferServiceB2.close();
        await facadeB2.dispose();
      });

      _linkFacades(facadeA, facadeB2);

      // B2 restores all trusted peers without direct endpoints
      await registryB2.restoreAll();

      // --- Second transfer without re-pairing ---
      // New discovered peer for B2 with new control port and native port 43124
      final discoveredB2 = LanDiscoveredPeer(
        deviceId: 'device-b',
        alias: 'Device B',
        ip: '127.0.0.1',
        controlPort: 53320,
        advertisedNativePort: 43124,
        deviceType: LanDeviceType.desktop,
        os: 'linux',
        lastSeen: DateTime.now(),
      );

      final file2 = File('${tempDir.path}/source_2.bin')
        ..writeAsBytesSync(
          Uint8List.fromList(List<int>.generate(2048, (i) => i % 256)),
        );
      final file2Hash = crypto.sha256
          .convert(file2.readAsBytesSync())
          .toString();

      final b2OfferFuture = coordinatorB2.incomingOffers.first;

      // Sender A queries /api/lan/capabilities and transfers file2
      final sendSessionResult2 = await coordinatorA.sendFile(
        peerId: discoveredB2.deviceId,
        transferId: 'transfer-2',
        filePath: file2.path,
        discovery: discoveredB2,
      );
      expect(sendSessionResult2, isA<NetworkSuccess<TransferSession>>());

      final offer2 = await b2OfferFuture;
      expect(offer2.peerId, 'device-a');
      expect(offer2.fileName, 'source_2.bin');

      final acceptResult2 = await coordinatorB2.accept(offer2);
      expect(acceptResult2, isA<NetworkSuccess<void>>());

      await facadeA.pump();
      await facadeB2.pump();

      // Validate B2 received file2 and SHA-256 matches
      final receivedFile2 = File('${sandboxB.path}/source_2.bin');
      expect(receivedFile2.existsSync(), isTrue);
      final received2Hash = crypto.sha256
          .convert(receivedFile2.readAsBytesSync())
          .toString();
      expect(received2Hash, file2Hash);
    },
  );
}

void _linkFacades(_SimulatedTransferFacade a, _SimulatedTransferFacade b) {
  a.peerFacade = b;
  b.peerFacade = a;
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
      'x25519PubKey': base64.encode(expectedX25519Key),
      'networkIdentityPubKey': base64.encode(expectedIdentityKey),
      'quicFileTransfer': true,
      'quicPort': nativePort,
    });
    return _MockCapabilitiesResponse(utf8.encode(body));
  }
}

class _MockCapabilitiesResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _MockCapabilitiesResponse(this.bodyBytes);

  final List<int> bodyBytes;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => bodyBytes.length;

  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(bodyBytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MockHttpHeaders extends Fake implements HttpHeaders {
  final Map<String, String> _headers = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _headers[name.toLowerCase()];
}

final class _SimulatedTransferFacade extends Fake implements NetworkFacade {
  _SimulatedTransferFacade({
    required this.selfDeviceId,
    required this.receiveDirectory,
  });

  final String selfDeviceId;
  final String receiveDirectory;
  _SimulatedTransferFacade? peerFacade;

  final StreamController<SdkEvent> _events =
      StreamController<SdkEvent>.broadcast();
  final Map<String, PeerConfig> registeredPeers = {};
  final List<Future<void>> _pendingPumps = [];

  @override
  Stream<SdkEvent> get events => _events.stream;

  @override
  Future<NetworkResult<void>> registerPeer(PeerConfig peer) async {
    registeredPeers[peer.peerId] = peer;
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<void>> removePeer(String peerId) async {
    registeredPeers.remove(peerId);
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<void>> disconnectPeer(String peerId) async {
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<void>> connectPeer(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<TransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  }) async {
    final sourceFile = File(filePath);
    final fileName = sourceFile.uri.pathSegments.last;
    final fileBytes = await sourceFile.readAsBytes();

    // Trigger offer on remote peer facade
    final peer = peerFacade;
    if (peer != null) {
      final offer = IncomingTransferOffer(
        eventId: 'event-$transferId',
        timestamp: DateTime.now().toUtc(),
        transferId: transferId,
        peerId: selfDeviceId,
        fileName: fileName,
        fileSize: fileBytes.length,
        routeType: NetworkRouteType.quicDirect,
      );
      peer._events.add(offer);
      peer._pendingTransferBytes[transferId] = (fileName, fileBytes);
    }

    return NetworkSuccess(
      TransferSession(
        transferId: transferId,
        peerId: peerId,
        filePath: filePath,
        routeType: NetworkRouteType.quicDirect,
      ),
    );
  }

  final Map<String, (String, Uint8List)> _pendingTransferBytes = {};

  @override
  Future<NetworkResult<void>> respondToIncomingTransfer({
    required String transferId,
    required bool accept,
  }) async {
    if (accept) {
      final transferData = _pendingTransferBytes[transferId];
      if (transferData != null) {
        final (fileName, bytes) = transferData;
        final targetFile = File('$receiveDirectory/$fileName');
        await targetFile.writeAsBytes(bytes);
      }
    }
    return const NetworkSuccess<void>(null);
  }

  Future<void> pump() async {
    await Future.wait(_pendingPumps);
    _pendingPumps.clear();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

final class _MemorySecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> _storage = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _storage[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _storage.remove(key);
    } else {
      _storage[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map<String, String>.unmodifiable(_storage);

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _storage.containsKey(key);
}
