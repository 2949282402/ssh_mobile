part of 'lan_receiver_coordinator_test.dart';

void _registerReceiverObservationTests() {
  test('incoming offer stream survives facade recreation', () async {
    final trustStore = LanPeerTrustStore();
    await trustStore.save(_trustRecord('peer-a'));
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final firstFacade = FakeLanShareNetworkService();
    final secondFacade = FakeLanShareNetworkService();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkAccess: FakeLanShareNetworkAccessPort(
        networkFacades: <NetworkFacade>[firstFacade, secondFacade],
      ),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      peerTrustStore: trustStore,
      transferServiceOverride: FakeLanTransferService(),
      discoveryServiceOverride: FakeLanDiscoveryService(),
    );
    final offers = <IncomingTransferOffer>[];
    final subscription = coordinator.nativeIncomingTransferOffers.listen(
      offers.add,
    );

    await coordinator.ensureInitialized();
    firstFacade.emitEvent(_offer('first'));
    await Future<void>.delayed(Duration.zero);
    await coordinator.deactivateReceiver();
    await coordinator.activateReceiver();
    secondFacade.emitEvent(_offer('second'));
    await Future<void>.delayed(Duration.zero);

    expect(offers.map((offer) => offer.transferId), <String>[
      'first',
      'second',
    ]);

    await subscription.cancel();
    await coordinator.close();
    await trustStore.dispose();
    settings.dispose();
    await database.dispose();
  });
}
