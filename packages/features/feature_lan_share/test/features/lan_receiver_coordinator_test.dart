// LAN Receiver 协调器生命周期与 Capability 门控测试。
//
// 测试覆盖：
// 1. 接收器初始化的共享与 ViewModel 创建；
// 2. 初始化只请求 `NetworkCapability.runtime`（而非 `quic`）；
// 3. Relay 配置前请求 `webSocketRelay` 能力；
// 4. `webSocketRelay` 被禁用时，Relay 配置快速失败且不向 native 发出命令。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;

  setUp(() {
    originalPathProvider = PathProviderPlatform.instance;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
  });

  test('receiver coordinator starts uninitialized', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkFactory: FakeLanShareNetworkFactory(),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      initializeNetwork: false,
    );

    expect(coordinator.initialized, isFalse);
    expect(coordinator.transferService, isNull);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test('receiver initialization is shared and creates one ViewModel', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkFactory: FakeLanShareNetworkFactory(),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      initializeNetwork: false,
    );

    final first = coordinator.ensureInitialized();
    expect(identical(first, coordinator.ensureInitialized()), isTrue);
    await first;
    expect(coordinator.initialized, isTrue);
    expect(coordinator.transferService, isNotNull);
    expect(coordinator.discoveryService, isNotNull);
    expect(coordinator.securityService, isNotNull);

    final viewModel = await coordinator.ensureViewModel();
    expect(identical(viewModel, await coordinator.ensureViewModel()), isTrue);
    expect(viewModel.ownsRuntime, isFalse);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test(
    'receiver initialization requests runtime capability, not quic',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings();
      final networkService = FakeLanShareNetworkService();
      final networkRuntime = FakeLanShareNetworkRuntime();
      final networkFactory = FakeLanShareNetworkFactory(
        networkFacade: networkService,
      );
      final discovery = FakeLanDiscoveryService();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkFactory: networkFactory,
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: networkRuntime,
        transferServiceOverride: FakeLanTransferService(),
        discoveryServiceOverride: discovery,
      );

      await coordinator.ensureInitialized();

      expect(
        networkRuntime.requestedCapabilities,
        contains(NetworkCapability.runtime),
      );
      expect(
        networkRuntime.requestedCapabilities,
        isNot(contains(NetworkCapability.quic)),
      );
      expect(networkService.startCalls, 1);
      expect(networkFactory.lastListenAddress, '0.0.0.0:0');
      expect(discovery.advertisedEndpoints, [
        (LanTransferService.defaultHttpPort, null),
        (LanTransferService.defaultHttpPort, 43123),
      ]);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test('paired native peers are restored before receiver use', () async {
    _seedPairedPeer(
      'peer-a',
      identityKey: _encodedKey(32, 1),
      e2eKey: _encodedKey(32, 2),
    );
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final networkService = FakeLanShareNetworkService();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkFactory: FakeLanShareNetworkFactory(networkFacade: networkService),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      transferServiceOverride: FakeLanTransferService(),
      discoveryServiceOverride: FakeLanDiscoveryService(),
    );

    await coordinator.ensureInitialized();

    expect(networkService.registerPeerCalls, 1);
    expect(networkService.connectPeerCalls, 0);
    expect(networkService.lastPeerConfig?.peerId, 'peer-a');
    expect(networkService.lastPeerConfig?.endpointAddress, isEmpty);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test(
    'incomplete or malformed paired native peers are not restored',
    () async {
      for (final fixture in <({String? identity, String? e2e})>[
        (identity: null, e2e: _encodedKey(32, 2)),
        (identity: _encodedKey(32, 1), e2e: null),
        (identity: _encodedKey(31, 1), e2e: _encodedKey(32, 2)),
        (identity: _encodedKey(32, 1), e2e: _encodedKey(33, 2)),
      ]) {
        _seedPairedPeer(
          'peer-a',
          identityKey: fixture.identity,
          e2eKey: fixture.e2e,
        );
        final database = LanShareDatabase.forTesting(NativeDatabase.memory());
        final settings = FakeLanShareSettings();
        final networkService = FakeLanShareNetworkService();
        final coordinator = LanReceiverCoordinator(
          appSettings: settings,
          logger: FakeLanShareLogger(),
          dataProtection: FakeLanShareDataProtection(),
          networkIdentity: FakeLanShareIdentity(),
          networkFactory: FakeLanShareNetworkFactory(
            networkFacade: networkService,
          ),
          bootstrapClient: FakeLanShareBootstrapClient(),
          historyRepository: LanShareHistoryRepository(database),
          networkRuntime: FakeLanShareNetworkRuntime(),
          transferServiceOverride: FakeLanTransferService(),
          discoveryServiceOverride: FakeLanDiscoveryService(),
        );

        await coordinator.ensureInitialized();
        expect(networkService.registerPeerCalls, 0, reason: '$fixture');

        await coordinator.close();
        settings.dispose();
        await database.dispose();
      }
    },
  );

  test('every new receiver runtime restores paired native peers', () async {
    _seedPairedPeer(
      'peer-a',
      identityKey: _encodedKey(32, 1),
      e2eKey: _encodedKey(32, 2),
    );
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final firstFacade = FakeLanShareNetworkService();
    final secondFacade = FakeLanShareNetworkService();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkFactory: FakeLanShareNetworkFactory(
        networkFacades: <NetworkFacade>[firstFacade, secondFacade],
      ),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
      transferServiceOverride: FakeLanTransferService(),
      discoveryServiceOverride: FakeLanDiscoveryService(),
    );

    await coordinator.ensureInitialized();
    await coordinator.deactivateReceiver();
    await coordinator.activateReceiver();

    expect(firstFacade.registerPeerCalls, 1);
    expect(secondFacade.registerPeerCalls, 1);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test('incoming offer stream survives facade recreation', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings();
    final firstFacade = FakeLanShareNetworkService();
    final secondFacade = FakeLanShareNetworkService();
    final coordinator = LanReceiverCoordinator(
      appSettings: settings,
      logger: FakeLanShareLogger(),
      dataProtection: FakeLanShareDataProtection(),
      networkIdentity: FakeLanShareIdentity(),
      networkFactory: FakeLanShareNetworkFactory(
        networkFacades: <NetworkFacade>[firstFacade, secondFacade],
      ),
      bootstrapClient: FakeLanShareBootstrapClient(),
      historyRepository: LanShareHistoryRepository(database),
      networkRuntime: FakeLanShareNetworkRuntime(),
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
    settings.dispose();
    await database.dispose();
  });

  test(
    'relay configuration requests webSocketRelay before configuring relay',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings();
      final networkService = FakeLanShareNetworkService();
      final networkRuntime = FakeLanShareNetworkRuntime();
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkFactory: FakeLanShareNetworkFactory(
          networkFacade: networkService,
        ),
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: networkRuntime,
        transferServiceOverride: FakeLanTransferService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );
      await coordinator.ensureInitialized();

      final result = await coordinator.enrollRelay(
        endpoint: Uri.parse('https://relay.example.test'),
        enrollmentToken: '0123456789abcdef',
      );

      expect(result, isA<NetworkSuccess<void>>());
      expect(
        networkRuntime.requestedCapabilities,
        contains(NetworkCapability.webSocketRelay),
      );
      expect(
        networkRuntime.requestedCapabilities,
        isNot(contains(NetworkCapability.quic)),
      );
      expect(networkService.configureRelayCalls, 1);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test(
    'webSocketRelay-disabled runtime refuses relay configuration fast',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings(
        relayEndpoint: 'https://relay.example.test',
      );
      final networkService = FakeLanShareNetworkService();
      final networkRuntime = FakeLanShareNetworkRuntime(
        refuseWebSocketRelay: true,
      );
      final coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: FakeLanShareLogger(),
        dataProtection: FakeLanShareDataProtection(),
        networkIdentity: FakeLanShareIdentity(),
        networkFactory: FakeLanShareNetworkFactory(
          networkFacade: networkService,
        ),
        bootstrapClient: FakeLanShareBootstrapClient(),
        historyRepository: LanShareHistoryRepository(database),
        networkRuntime: networkRuntime,
        transferServiceOverride: FakeLanTransferService(),
        discoveryServiceOverride: FakeLanDiscoveryService(),
      );
      await coordinator.ensureInitialized();

      final result = await coordinator.connectConfiguredRelay();

      expect(result, isA<NetworkFailure<void>>());
      expect(
        (result as NetworkFailure<void>).error.code,
        NetworkErrorCode.relayError,
      );
      expect(
        networkRuntime.requestedCapabilities,
        contains(NetworkCapability.webSocketRelay),
      );
      expect(networkService.configureRelayCalls, 0);
      expect(networkService.disconnectRelayCalls, 0);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test(
    'data-plane credentialExpired triggers silent refresh and reconfigure',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings(
        relayEndpoint: 'https://relay.example.test',
      );
      final networkService = FakeLanShareNetworkService();
      final bootstrap = FakeLanShareBootstrapClient();
      final coordinator = _buildRelayCoordinator(
        database,
        settings,
        networkService,
        bootstrap,
      );
      await coordinator.ensureInitialized();

      final enroll = await coordinator.enrollRelay(
        endpoint: Uri.parse('https://relay.example.test'),
        enrollmentToken: '0123456789abcdef',
      );
      expect(enroll, isA<NetworkSuccess<void>>());
      expect(networkService.configureRelayCalls, 1);

      networkService.emitRelayState(
        RelayConnectionState.failed,
        error: const NetworkError(
          code: NetworkErrorCode.credentialExpired,
          message: 'Relay credential expired.',
          operation: NetworkOperation.connectRelay,
          retryDisposition: RetryDisposition.refreshCredentialThenRetry,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bootstrap.refreshCalls, 1);
      expect(networkService.configureRelayCalls, 2);
      expect(coordinator.relayStatus.enrolled, isTrue);
      expect(coordinator.relayStatus.error, isNull);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test('refresh 404 stops retry and surfaces a re-enroll signal', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings(
      relayEndpoint: 'https://relay.example.test',
    );
    final networkService = FakeLanShareNetworkService();
    final bootstrap = FakeLanShareBootstrapClient(
      onRefresh: (endpoint, request) async => SdkFailure(
        const NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'Relay device is not enrolled.',
          operation: NetworkOperation.refreshCredential,
        ),
      ),
    );
    final coordinator = _buildRelayCoordinator(
      database,
      settings,
      networkService,
      bootstrap,
    );
    await coordinator.ensureInitialized();
    await coordinator.enrollRelay(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    networkService.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.credentialExpired,
        message: 'Relay credential expired.',
        operation: NetworkOperation.connectRelay,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(bootstrap.refreshCalls, 1);
    expect(networkService.configureRelayCalls, 1);
    expect(coordinator.relayStatus.enrolled, isFalse);
    expect(coordinator.relayStatus.error?.code, NetworkErrorCode.noRoute);
    expect(coordinator.relayStatus.reconnectAttempt, 0);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test(
    'retryAfter disposition schedules a reconnect after server seconds',
    () async {
      final database = LanShareDatabase.forTesting(NativeDatabase.memory());
      final settings = FakeLanShareSettings(
        relayEndpoint: 'https://relay.example.test',
      );
      final networkService = FakeLanShareNetworkService();
      final coordinator = _buildRelayCoordinator(
        database,
        settings,
        networkService,
        FakeLanShareBootstrapClient(),
      );
      await coordinator.ensureInitialized();
      await coordinator.enrollRelay(
        endpoint: Uri.parse('https://relay.example.test'),
        enrollmentToken: '0123456789abcdef',
      );
      expect(networkService.configureRelayCalls, 1);

      networkService.emitRelayState(
        RelayConnectionState.failed,
        error: const NetworkError(
          code: NetworkErrorCode.relayError,
          message: 'Relay is busy.',
          operation: NetworkOperation.connectRelay,
          retryDisposition: RetryDisposition.retryAfter,
          retryAfterSeconds: 1,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 重连尚未到达服务器建议的 1 秒。
      expect(networkService.configureRelayCalls, 1);
      expect(coordinator.relayStatus.reconnectAttempt, 1);

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(networkService.configureRelayCalls, 2);

      await coordinator.close();
      settings.dispose();
      await database.dispose();
    },
  );

  test('noRetry disposition stops automatic reconnect', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings(
      relayEndpoint: 'https://relay.example.test',
    );
    final networkService = FakeLanShareNetworkService();
    final coordinator = _buildRelayCoordinator(
      database,
      settings,
      networkService,
      FakeLanShareBootstrapClient(),
    );
    await coordinator.ensureInitialized();
    await coordinator.enrollRelay(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    networkService.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.relayError,
        message: 'Do not retry.',
        operation: NetworkOperation.connectRelay,
        retryDisposition: RetryDisposition.noRetry,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(networkService.configureRelayCalls, 1);
    expect(coordinator.relayStatus.reconnectAttempt, 0);
    expect(
      coordinator.relayStatus.error?.retryDisposition,
      RetryDisposition.noRetry,
    );

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });

  test('identityConflict is terminal and is surfaced without retry', () async {
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
    final settings = FakeLanShareSettings(
      relayEndpoint: 'https://relay.example.test',
    );
    final networkService = FakeLanShareNetworkService();
    final coordinator = _buildRelayCoordinator(
      database,
      settings,
      networkService,
      FakeLanShareBootstrapClient(),
    );
    await coordinator.ensureInitialized();
    await coordinator.enrollRelay(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    networkService.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.identityConflict,
        message: 'Relay device identity conflicts.',
        operation: NetworkOperation.connectRelay,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(networkService.configureRelayCalls, 1);
    expect(
      coordinator.relayStatus.error?.code,
      NetworkErrorCode.identityConflict,
    );
    expect(coordinator.relayStatus.reconnectAttempt, 0);

    await coordinator.close();
    settings.dispose();
    await database.dispose();
  });
}

/// 构建一个注入 fake 网络、runtime 与 bootstrap 的 Relay 协调器。
LanReceiverCoordinator _buildRelayCoordinator(
  LanShareDatabase database,
  FakeLanShareSettings settings,
  FakeLanShareNetworkService networkService,
  FakeLanShareBootstrapClient bootstrapClient,
) {
  return LanReceiverCoordinator(
    appSettings: settings,
    logger: FakeLanShareLogger(),
    dataProtection: FakeLanShareDataProtection(),
    networkIdentity: FakeLanShareIdentity(),
    networkFactory: FakeLanShareNetworkFactory(networkFacade: networkService),
    bootstrapClient: bootstrapClient,
    historyRepository: LanShareHistoryRepository(database),
    networkRuntime: FakeLanShareNetworkRuntime(),
    transferServiceOverride: FakeLanTransferService(),
    discoveryServiceOverride: FakeLanDiscoveryService(),
  );
}

/// 返回可写的应用文档目录，避免单元测试依赖平台插件通道。
final class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/lan_share_test_documents';

  @override
  Future<String?> getTemporaryPath() async => '/tmp/lan_share_test_tmp';
}

String _encodedKey(int length, int value) =>
    base64UrlEncode(List<int>.filled(length, value)).replaceAll('=', '');

void _seedPairedPeer(String deviceId, {String? identityKey, String? e2eKey}) {
  final identityKeys = <String, String>{};
  final e2eKeys = <String, String>{};
  if (identityKey != null) identityKeys[deviceId] = identityKey;
  if (e2eKey != null) e2eKeys[deviceId] = e2eKey;
  FlutterSecureStorage.setMockInitialValues(<String, String>{
    'lan_share_paired_device_ids': jsonEncode(<String, int>{deviceId: 0}),
    'lan_share_outbound_access_tokens': jsonEncode(<String, String>{
      deviceId: 'test-token',
    }),
    'lan_share_peer_certificate_fingerprints': jsonEncode(<String, String>{
      deviceId: 'a' * 64,
    }),
    'lan_share_peer_network_identity_keys_v1': jsonEncode(identityKeys),
    'lan_share_peer_x25519_keys_v1': jsonEncode(e2eKeys),
  });
}

IncomingTransferOffer _offer(String id) => IncomingTransferOffer(
  eventId: 'event-$id',
  timestamp: DateTime.now(),
  transferId: id,
  peerId: 'peer-a',
  fileName: '$id.bin',
  fileSize: 1,
);
