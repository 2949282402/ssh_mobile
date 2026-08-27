import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('restoreAll registers every trusted peer without connecting', () async {
    final store = LanPeerTrustStore();
    final facade = _RecordingFacade();
    final registry = LanNativePeerRegistry(
      trustStore: store,
      networkFacade: facade,
    );
    addTearDown(store.dispose);

    await store.save(_record('peer-a'));
    await store.save(_record('peer-b'));

    await registry.restoreAll();
    expect(facade.registrations, hasLength(2));
    expect(
      facade.registrations.map((peer) => peer.peerId),
      containsAll(<String>['peer-a', 'peer-b']),
    );
    expect(facade.connectCalls, 0);
    expect(facade.removedPeerIds, isEmpty);
  });

  test('endpoint observations update only the native registration', () async {
    final store = LanPeerTrustStore();
    final facade = _RecordingFacade();
    final registry = LanNativePeerRegistry(
      trustStore: store,
      networkFacade: facade,
    );
    addTearDown(store.dispose);
    await store.save(_record('peer-a'));

    final updated = await registry.updateDirectEndpoint('peer-a', '10.0.0.2:9');
    expect(updated, isA<SdkSuccess<void>>());
    expect(facade.registrations.last.endpointAddress, '10.0.0.2:9');
    expect(facade.connectCalls, 0);

    final invalidated = await registry.invalidateDirectEndpoint('peer-a');
    expect(invalidated, isA<SdkSuccess<void>>());
    expect(facade.registrations.last.endpointAddress, isEmpty);
    expect(facade.connectCalls, 0);
  });

  test('resolves only the currently trusted direct native endpoint', () async {
    final store = LanPeerTrustStore();
    final facade = _RecordingFacade();
    final registry = LanNativePeerRegistry(
      trustStore: store,
      networkFacade: facade,
    );
    addTearDown(store.dispose);
    await store.save(_record('peer-a'));

    expect(registry.peerIdForEndpoint('192.0.2.5', 43123), isNull);
    await registry.updateDirectEndpoint('peer-a', '192.0.2.5:43123');
    expect(registry.peerIdForEndpoint('192.0.2.5', 43123), 'peer-a');
    expect(registry.peerIdForEndpoint('192.0.2.5', 22), isNull);
    expect(registry.peerIdForHost('192.0.2.5'), 'peer-a');
    expect(registry.peerIdForHost('192.0.2.5:22'), isNull);

    await registry.invalidateDirectEndpoint('peer-a');
    expect(registry.peerIdForEndpoint('192.0.2.5', 43123), isNull);
    expect(registry.peerIdForHost('192.0.2.5'), isNull);
  });

  test('ambiguous endpoint ownership fails closed', () async {
    final store = LanPeerTrustStore();
    final facade = _RecordingFacade();
    final registry = LanNativePeerRegistry(
      trustStore: store,
      networkFacade: facade,
    );
    addTearDown(store.dispose);
    await store.save(_record('peer-a'));
    await store.save(_record('peer-b'));

    await registry.updateDirectEndpoint('peer-a', '192.0.2.5:43123');
    await registry.updateDirectEndpoint('peer-b', '192.0.2.5:43123');

    expect(registry.peerIdForEndpoint('192.0.2.5', 43123), isNull);
    expect(registry.peerIdForHost('192.0.2.5'), isNull);
  });

  test(
    'discovery sync uses only the ephemeral native port, never the HTTPS port',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));

      await registry.syncDiscoveredEndpoints(<LanDiscoveredPeer>[
        LanDiscoveredPeer(
          deviceId: 'peer-a',
          alias: 'Peer A',
          ip: '192.0.2.5',
          controlPort: 53317,
          deviceType: LanDeviceType.desktop,
          os: 'linux',
          lastSeen: DateTime.utc(2026),
        ),
      ]);
      // Discovery without the advertised native endpoint is not enough to
      // create a native route and must not overwrite the restored trust-only
      // registration.
      expect(facade.registrations, isEmpty);

      await registry.syncDiscoveredEndpoints(<LanDiscoveredPeer>[
        LanDiscoveredPeer(
          deviceId: 'peer-a',
          alias: 'Peer A',
          ip: '192.0.2.5',
          controlPort: 53317,
          advertisedNativePort: 43123,
          deviceType: LanDeviceType.desktop,
          os: 'linux',
          lastSeen: DateTime.utc(2026),
        ),
      ]);
      expect(facade.registrations.last.endpointAddress, '192.0.2.5:43123');
    },
  );

  test(
    'discovery endpoint loss invalidates route but preserves trust',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(trustStore: store);
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));
      registry.attachFacade(facade);

      await registry.syncDiscoveredEndpoints(<LanDiscoveredPeer>[
        LanDiscoveredPeer(
          deviceId: 'peer-a',
          alias: 'Peer A',
          ip: '2001:db8::2',
          controlPort: 53317,
          advertisedNativePort: 43123,
          deviceType: LanDeviceType.desktop,
          os: 'test',
          lastSeen: DateTime.utc(2026),
        ),
      ]);
      expect(facade.registrations.last.endpointAddress, '[2001:db8::2]:43123');

      await registry.syncDiscoveredEndpoints(const <LanDiscoveredPeer>[]);
      expect(facade.registrations.last.endpointAddress, isEmpty);
      expect(await store.read('peer-a'), isNotNull);
    },
  );

  test(
    'single peer observation preserves other active discovery endpoints',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));
      await store.save(_record('peer-b'));

      await registry.syncDiscoveredEndpoints(<LanDiscoveredPeer>[
        _discovered('peer-a', '192.0.2.10', 43101),
        _discovered('peer-b', '192.0.2.11', 43102),
      ]);
      await registry.observeDiscoveredEndpoint(
        _discovered('peer-b', '192.0.2.12', 43103),
      );

      expect(registry.peerIdForHost('192.0.2.10'), 'peer-a');
      expect(registry.peerIdForHost('192.0.2.12'), 'peer-b');
      expect(registry.peerIdForHost('192.0.2.11'), isNull);
      expect(
        facade.registrations
            .lastWhere((peer) => peer.peerId == 'peer-a')
            .endpointAddress,
        '192.0.2.10:43101',
      );
      expect(
        facade.registrations
            .lastWhere((peer) => peer.peerId == 'peer-b')
            .endpointAddress,
        '192.0.2.12:43103',
      );
    },
  );

  test(
    'relay authorization changes are persisted with the same peer identity',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));

      final authorized = await registry.authorizeRelayForPeer('peer-a');
      expect(authorized, isA<SdkSuccess<void>>());
      expect(facade.registrations.last.allowDirect, isTrue);
      expect(facade.registrations.last.allowRelay, isTrue);
      expect((await store.read('peer-a'))?.authorization.relay, isTrue);

      final revoked = await registry.revokeRelayForPeer('peer-a');
      expect(revoked, isA<SdkSuccess<void>>());
      expect(facade.registrations.last.allowDirect, isTrue);
      expect(facade.registrations.last.allowRelay, isFalse);
      expect((await store.read('peer-a'))?.authorization.relay, isFalse);
    },
  );

  test(
    'removeTrust deletes persisted material and explicitly removes native peer',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));
      await registry.updateDirectEndpoint('peer-a', '10.0.0.2:9');

      final result = await registry.removeTrust('peer-a');

      expect(result, isA<SdkSuccess<void>>());
      expect(await store.read('peer-a'), isNull);
      expect(facade.removedPeerIds, <String>['peer-a']);
      expect(facade.connectCalls, 0);
    },
  );

  test('endpoint update fails closed when the peer is not trusted', () async {
    final store = LanPeerTrustStore();
    final facade = _RecordingFacade();
    final registry = LanNativePeerRegistry(
      trustStore: store,
      networkFacade: facade,
    );
    addTearDown(store.dispose);

    final result = await registry.updateDirectEndpoint('unknown', '10.0.0.2:9');

    expect(result, isA<SdkFailure<void>>());
    final failure = result as SdkFailure<void>;
    expect(failure.error.code, NetworkErrorCode.authenticationFailed);
    expect(facade.registrations, isEmpty);
  });

  test(
    'relay grant native registration failure keeps persistent relay false',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));

      facade.failRegisterPeer = true;
      final result = await registry.authorizeRelayForPeer('peer-a');

      expect(result, isA<SdkFailure<void>>());
      expect((await store.read('peer-a'))?.authorization.relay, isFalse);
    },
  );

  test(
    'relay revoke native failure keeps persistent false and disconnects/removes peer',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(
        _record('peer-a').copyWith(
          authorization: const PeerRouteAuthorization(
            localDirect: true,
            relay: true,
          ),
        ),
      );

      facade.failRegisterPeer = true;
      final result = await registry.revokeRelayForPeer('peer-a');

      expect(result, isA<SdkFailure<void>>());
      expect((await store.read('peer-a'))?.authorization.relay, isFalse);
      expect(facade.disconnectedPeerIds, contains('peer-a'));
      expect(facade.removedPeerIds, contains('peer-a'));
    },
  );

  test(
    'unpair removePeer failure keeps persistent trust deleted and tombstones peer',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));

      facade.failRemovePeer = true;
      final result = await registry.removeTrust('peer-a');

      expect(result, isA<SdkFailure<void>>());
      expect(await store.read('peer-a'), isNull);

      // Discovery after unpair must not resurrect or re-register the unpinned peer
      await registry.syncDiscoveredEndpoints(<LanDiscoveredPeer>[
        LanDiscoveredPeer(
          deviceId: 'peer-a',
          alias: 'Peer A',
          ip: '192.0.2.5',
          controlPort: 53317,
          advertisedNativePort: 43123,
          deviceType: LanDeviceType.desktop,
          os: 'linux',
          lastSeen: DateTime.utc(2026),
        ),
      ]);
      expect(facade.registrations, isEmpty);

      final updateRes = await registry.updateDirectEndpoint(
        'peer-a',
        '192.0.2.5:43123',
      );
      expect(updateRes, isA<SdkFailure<void>>());
      expect(
        (updateRes as SdkFailure<void>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
    },
  );

  test(
    'concurrent grant and revoke operations resolve deterministically',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));

      final futures = await Future.wait([
        registry.authorizeRelayForPeer('peer-a'),
        registry.revokeRelayForPeer('peer-a'),
      ]);

      expect(futures[0], isA<SdkSuccess<void>>());
      expect(futures[1], isA<SdkSuccess<void>>());
      final record = await store.read('peer-a');
      expect(record?.authorization.relay, isFalse);
      expect(facade.registrations.last.allowRelay, isFalse);
    },
  );

  test(
    'relay revoke native failure and removePeer failure keeps peer runtime-blocked',
    () async {
      final store = LanPeerTrustStore();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(
        _record('peer-a').copyWith(
          authorization: const PeerRouteAuthorization(
            localDirect: true,
            relay: true,
          ),
        ),
      );

      facade.failRegisterPeer = true;
      facade.failRemovePeer = true;
      final result = await registry.revokeRelayForPeer('peer-a');

      expect(result, isA<SdkFailure<void>>());
      expect((await store.read('peer-a'))?.authorization.relay, isFalse);
      expect(registry.isPeerBlocked('peer-a'), isTrue);

      // Blocked peer must reject endpoint updates
      final updateResult = await registry.updateDirectEndpoint(
        'peer-a',
        '10.0.0.2:9',
      );
      expect(updateResult, isA<SdkFailure<void>>());
      expect(
        (updateResult as SdkFailure<void>).error.code,
        NetworkErrorCode.securityPolicyMismatch,
      );

      // Blocked peer is ignored during discovery sync
      facade.registrations.clear();
      await registry.syncDiscoveredEndpoints(<LanDiscoveredPeer>[
        LanDiscoveredPeer(
          deviceId: 'peer-a',
          alias: 'Peer A',
          ip: '10.0.0.2',
          controlPort: 53317,
          advertisedNativePort: 43123,
          deviceType: LanDeviceType.desktop,
          os: 'linux',
          lastSeen: DateTime.utc(2026),
        ),
      ]);
      expect(facade.registrations, isEmpty);

      // Successful restoreAll clears blocked status
      facade.failRegisterPeer = false;
      await registry.restoreAll();
      expect(registry.isPeerBlocked('peer-a'), isFalse);
    },
  );

  test(
    'registry does not retain discovery endpoint without a facade',
    () async {
      final store = LanPeerTrustStore();
      final registry = LanNativePeerRegistry(trustStore: store);
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));

      final result = await registry.updateDirectEndpoint(
        'peer-a',
        '10.0.0.2:9',
      );
      expect(result, isA<SdkFailure<void>>());

      final facade = _RecordingFacade();
      registry.attachFacade(facade);
      await registry.restoreAll();
      expect(facade.registrations.single.endpointAddress, isEmpty);
    },
  );

  test(
    'revoke relay persistence failure returns NetworkFailure and keeps persistent true without native change',
    () async {
      final storage = _FailingSecureStorage();
      final store = LanPeerTrustStore(secureStorage: storage);
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(
        _record('peer-a').copyWith(
          authorization: const PeerRouteAuthorization(
            localDirect: true,
            relay: true,
          ),
        ),
      );
      facade.registrations.clear();

      storage.failWrite = true;
      final result = await registry.revokeRelayForPeer('peer-a');

      expect(result, isA<SdkFailure<void>>());
      final failure = result as SdkFailure<void>;
      expect(failure.error.operation, NetworkOperation.upsertPeer);
      expect(failure.error.peerId, 'peer-a');

      storage.failWrite = false;
      expect((await store.read('peer-a'))?.authorization.relay, isTrue);
      expect(facade.registrations, isEmpty);
      expect(facade.removedPeerIds, isEmpty);
      expect(registry.isPeerBlocked('peer-a'), isFalse);
    },
  );

  test(
    'grant persistence failure with rollback success returns NetworkFailure and restores native allowRelay=false',
    () async {
      final storage = _FailingSecureStorage();
      final store = LanPeerTrustStore(secureStorage: storage);
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));
      facade.registrations.clear();

      storage.failWrite = true;
      final result = await registry.authorizeRelayForPeer('peer-a');

      expect(result, isA<SdkFailure<void>>());
      final failure = result as SdkFailure<void>;
      expect(failure.error.operation, NetworkOperation.upsertPeer);
      expect(failure.error.peerId, 'peer-a');

      storage.failWrite = false;
      expect((await store.read('peer-a'))?.authorization.relay, isFalse);

      expect(facade.registrations, hasLength(2));
      expect(facade.registrations[0].allowRelay, isTrue);
      expect(facade.registrations[1].allowRelay, isFalse);
      expect(facade.removedPeerIds, isEmpty);
      expect(registry.isPeerBlocked('peer-a'), isFalse);
    },
  );

  test(
    'grant persistence failure with rollback and remove failure keeps persistent false and runtime-blocks peer',
    () async {
      final storage = _FailingSecureStorage();
      final store = LanPeerTrustStore(secureStorage: storage);
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );
      addTearDown(store.dispose);
      await store.save(_record('peer-a'));
      facade.registrations.clear();

      storage.failWrite = true;
      facade.failRegisterPeerOnCall =
          2; // Initial grant (call 1) succeeds; rollback _register (call 2) fails
      facade.failRemovePeer = true; // _forceRemoveNativePeer will fail
      final result = await registry.authorizeRelayForPeer('peer-a');

      expect(result, isA<SdkFailure<void>>());
      storage.failWrite = false;
      expect((await store.read('peer-a'))?.authorization.relay, isFalse);
      expect(registry.isPeerBlocked('peer-a'), isTrue);

      final updateResult = await registry.updateDirectEndpoint(
        'peer-a',
        '10.0.0.2:9',
      );
      expect(updateResult, isA<SdkFailure<void>>());
      expect(
        (updateResult as SdkFailure<void>).error.code,
        NetworkErrorCode.securityPolicyMismatch,
      );
    },
  );
}

final class _FailingSecureStorage extends Fake implements FlutterSecureStorage {
  bool failWrite = false;
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

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
    if (failWrite) {
      throw Exception('Simulated secure storage write failure');
    }
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
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
    data.remove(key);
  }
}

final class _RecordingFacade extends Fake implements NetworkFacade {
  final List<SdkPeerConfig> registrations = <SdkPeerConfig>[];
  final List<String> removedPeerIds = <String>[];
  final List<String> disconnectedPeerIds = <String>[];
  int connectCalls = 0;
  int registerPeerCalls = 0;
  bool failRegisterPeer = false;
  int? failRegisterPeerOnCall;
  bool failRemovePeer = false;
  bool failDisconnectPeer = false;

  @override
  Future<SdkResult<void>> registerPeer(SdkPeerConfig peer) async {
    registerPeerCalls++;
    if (failRegisterPeer ||
        (failRegisterPeerOnCall != null &&
            registerPeerCalls == failRegisterPeerOnCall)) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Simulated native registerPeer failure.',
          operation: NetworkOperation.upsertPeer,
          peerId: peer.peerId,
        ),
      );
    }
    registrations.add(peer);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> removePeer(String peerId) async {
    if (failRemovePeer) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Simulated native removePeer failure.',
          operation: NetworkOperation.removePeer,
          peerId: peerId,
        ),
      );
    }
    removedPeerIds.add(peerId);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> disconnectPeer(String peerId) async {
    if (failDisconnectPeer) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Simulated native disconnectPeer failure.',
          operation: NetworkOperation.disconnect,
          peerId: peerId,
        ),
      );
    }
    disconnectedPeerIds.add(peerId);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    connectCalls++;
    return const SdkSuccess<void>(null);
  }
}

LanPeerTrustRecord _record(String deviceId) => LanPeerTrustRecord(
  deviceId: deviceId,
  certificateFingerprint:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  inboundAccessToken: 'inbound-$deviceId',
  outboundAccessToken: 'outbound-$deviceId',
  x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
  networkIdentityPublicKey: Uint8List.fromList(List<int>.filled(32, 0x22)),
  origin: PeerTrustOrigin.localPin,
  authorization: const PeerRouteAuthorization(localDirect: true, relay: false),
  createdAt: DateTime.utc(2026, 1, 1),
);

LanDiscoveredPeer _discovered(String deviceId, String ip, int nativePort) =>
    LanDiscoveredPeer(
      deviceId: deviceId,
      alias: deviceId,
      ip: ip,
      controlPort: 53317,
      advertisedNativePort: nativePort,
      deviceType: LanDeviceType.desktop,
      os: 'linux',
      lastSeen: DateTime.utc(2026),
    );
