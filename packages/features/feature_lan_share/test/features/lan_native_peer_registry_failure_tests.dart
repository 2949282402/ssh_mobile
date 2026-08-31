part of 'lan_native_peer_registry_v2_test.dart';

void _registerRegistryFailureTests() {
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
