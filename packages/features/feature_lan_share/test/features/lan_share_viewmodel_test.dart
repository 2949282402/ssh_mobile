import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('LanDiscoveredPeer preserves the independent native transfer port', () {
    final peer = LanDiscoveredPeer(
      deviceId: 'peer-1',
      alias: 'Peer 1',
      ip: '192.168.1.5',
      controlPort: 5432,
      advertisedNativePort: 6543,
      deviceType: LanDeviceType.mobile,
      os: 'android',
      lastSeen: DateTime.utc(2026, 8, 25),
    );

    final decoded = LanDiscoveredPeer.fromJson(peer.toJson());

    expect(decoded.controlPort, 5432);
    expect(decoded.advertisedNativePort, 6543);
  });

  test(
    'LanShareViewModel forgetDevice fails closed without coordinator',
    () async {
      final security = FakeLanSecurityService();
      final settings = FakeLanShareSettings();
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: FakeLanTransferService(),
        historyDao: FakeLanHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      await expectLater(
        viewModel.forgetDevice('test-device-id'),
        throwsStateError,
      );

      viewModel.dispose();
      settings.dispose();
    },
  );

  test(
    'text and clipboard fail closed when E2E capability is absent',
    () async {
      final security = _MissingKeySecurityService();
      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );
      final settings = FakeLanShareSettings();
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        historyDao: FakeLanHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );
      final device = LanDiscoveredPeer(
        deviceId: 'peer-1',
        alias: 'Peer 1',
        ip: '192.168.1.5',
        controlPort: 5432,
        deviceType: LanDeviceType.mobile,
        os: 'android',
        lastSeen: DateTime.now(),
      );

      final results = (
        await viewModel.sendText(device, 'hello'),
        await viewModel.sendClipboard(device, 'clipboard'),
      );
      expect(results.$1, isA<NetworkFailure<void>>());
      expect(
        (results.$1 as NetworkFailure<void>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(results.$2, isA<NetworkFailure<void>>());

      viewModel.dispose();
      settings.dispose();
      await transfer.close();
    },
  );

  test(
    'setRelayAuthorization routes through coordinator and updates projection',
    () async {
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      );
      final settings = FakeLanShareSettings();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );

      final record = LanPeerTrustRecord(
        deviceId: 'peer-1',
        certificateFingerprint:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        inboundAccessToken: 'inbound',
        outboundAccessToken: 'outbound',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      );
      await registry.registerTrust(record);

      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );

      final coordinator = LanNativeTransferCoordinator(
        transferService: transfer,
        networkFacade: facade,
        trustStore: store,
        updateDirectEndpoint: registry.updateDirectEndpoint,
        invalidateDirectEndpoint: registry.invalidateDirectEndpoint,
        removeTrust: registry.removeTrust,
        setRelayAuthorization: (deviceId, enabled) => enabled
            ? registry.authorizeRelayForPeer(deviceId)
            : registry.revokeRelayForPeer(deviceId),
      );

      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        nativeTransferCoordinator: coordinator,
        historyDao: FakeLanHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      await viewModel.initialize();

      expect(
        viewModel.peerStateFor('peer-1')?.trust?.authorization.relay,
        isFalse,
      );

      final grantResult = await viewModel.setRelayAuthorization('peer-1', true);
      expect(grantResult, isA<NetworkSuccess<void>>());
      expect(
        viewModel.peerStateFor('peer-1')?.trust?.authorization.relay,
        isTrue,
      );

      final revokeResult = await viewModel.setRelayAuthorization(
        'peer-1',
        false,
      );
      expect(revokeResult, isA<NetworkSuccess<void>>());
      expect(
        viewModel.peerStateFor('peer-1')?.trust?.authorization.relay,
        isFalse,
      );

      viewModel.dispose();
      await coordinator.dispose();
      await transfer.close();
      await store.dispose();
      settings.dispose();
    },
  );

  test(
    'toggling relay authorization repeatedly does not leak trustStore subscriptions',
    () async {
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      );
      final settings = FakeLanShareSettings();
      final facade = _RecordingFacade();
      final registry = LanNativePeerRegistry(
        trustStore: store,
        networkFacade: facade,
      );

      final record = LanPeerTrustRecord(
        deviceId: 'peer-1',
        certificateFingerprint:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        inboundAccessToken: 'inbound',
        outboundAccessToken: 'outbound',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      );
      await registry.registerTrust(record);

      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );

      final coordinator = LanNativeTransferCoordinator(
        transferService: transfer,
        networkFacade: facade,
        trustStore: store,
        updateDirectEndpoint: registry.updateDirectEndpoint,
        invalidateDirectEndpoint: registry.invalidateDirectEndpoint,
        removeTrust: registry.removeTrust,
        setRelayAuthorization: (deviceId, enabled) => enabled
            ? registry.authorizeRelayForPeer(deviceId)
            : registry.revokeRelayForPeer(deviceId),
      );

      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        nativeTransferCoordinator: coordinator,
        historyDao: FakeLanHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      await viewModel.initialize();

      // Toggle relay 10 times
      for (var i = 0; i < 10; i++) {
        await viewModel.setRelayAuthorization('peer-1', i.isEven);
      }

      int notifyCount = 0;
      viewModel.addListener(() {
        notifyCount++;
      });

      // Saving one update to trustStore directly should trigger stream change
      // and cause exactly ONE notifyListeners call, rather than 10+ duplicate callbacks.
      await store.save(
        record.copyWith(
          authorization: const PeerRouteAuthorization(
            localDirect: true,
            relay: true,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notifyCount, 1);

      viewModel.dispose();
      await coordinator.dispose();
      await transfer.close();
      await store.dispose();
      settings.dispose();
    },
  );
}

final class _MissingKeySecurityService extends Fake
    implements LanSecurityService {
  @override
  Future<Uint8List?> getPeerX25519PublicKey(String deviceId) async => null;

  @override
  Future<Uint8List?> getPeerNetworkIdentityPublicKey(String deviceId) async =>
      null;

  @override
  Future<String?> getPeerCertificateFingerprint(String deviceId) async => null;

  @override
  Future<String?> getOutboundAccessToken(String deviceId) async => 'token';

  @override
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async => true;
}

final class _RecordingFacade extends Fake implements NetworkFacade {
  final List<PeerConfig> registrations = <PeerConfig>[];

  @override
  Future<NetworkResult<void>> registerPeer(PeerConfig peer) async {
    registrations.add(peer);
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<void>> removePeer(String peerId) async {
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<void>> disconnectPeer(String peerId) async {
    return const NetworkSuccess<void>(null);
  }

  @override
  Stream<SdkEvent> get events => const Stream<SdkEvent>.empty();
}
