import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/features/lan_share/viewmodels/lan_share_viewmodel.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_discovery_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/data/database/app_database.dart';

class FakeLanSecurityService extends Fake implements LanSecurityService {
  String? unpairedDeviceId;

  @override
  Future<void> unpairDevice(String deviceId) async {
    unpairedDeviceId = deviceId;
  }
}

class FakeLanTransferService extends Fake implements LanTransferService {}

class FakeLanDiscoveryService extends Fake implements LanDiscoveryService {}

class FakeLanHistoryDao extends Fake implements LanHistoryDao {}

class FakeLanStorageService extends Fake implements LanStorageService {}

class FakeAppSettings extends Fake implements AppSettings {}

void main() {
  group('LanShareViewModel Forget Device Test', () {
    test('forgetDevice should unpair the device', () async {
      final securityService = FakeLanSecurityService();

      final vm = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        transferService: FakeLanTransferService(),
        securityService: securityService,
        historyDao: FakeLanHistoryDao(),
        storageService: FakeLanStorageService(),
        appSettings: FakeAppSettings(),
      );

      await vm.forgetDevice('test-device-id');

      expect(securityService.unpairedDeviceId, 'test-device-id');
    });
  });
}
