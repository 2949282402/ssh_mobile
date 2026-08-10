import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  test('LanShareViewModel forgetDevice clears the paired device', () async {
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

    await viewModel.forgetDevice('test-device-id');

    expect(security.unpairedDeviceId, 'test-device-id');
    viewModel.dispose();
    settings.dispose();
  });
}
