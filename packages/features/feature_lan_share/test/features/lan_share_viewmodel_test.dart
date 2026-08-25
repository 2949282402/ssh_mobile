import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
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
