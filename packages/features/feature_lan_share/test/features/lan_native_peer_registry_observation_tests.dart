part of 'lan_native_peer_registry_v2_test.dart';

void _registerRegistryObservationTests() {
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
}
