part of 'lan_native_peer_registry_v2_test.dart';

void _registerRegistryRestoreTests() {
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
}
