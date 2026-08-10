import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
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
}
