part of 'lan_native_peer_registry_v2_test.dart';

void _registerRegistryPolicyTests() {
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
}
