import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets('settings screen renders inside the Feature provider scope', (
    tester,
  ) async {
    final settings = FakeLanShareSettings();
    final viewModel = _createViewModel(settings);
    addTearDown(() {
      viewModel.dispose();
      settings.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
        ],
        child: const MaterialApp(home: LanShareSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LanShareSettingsScreen), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings screen opens the route-scoped Relay editor', (
    tester,
  ) async {
    final settings = FakeLanShareSettings();
    final viewModel = _createViewModel(settings);
    final database = LanShareDatabase.forTesting(NativeDatabase.memory());
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
    addTearDown(() async {
      await coordinator.close();
      await database.dispose();
      viewModel.dispose();
      settings.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
          ChangeNotifierProvider<LanReceiverCoordinator>.value(
            value: coordinator,
          ),
        ],
        child: const MaterialApp(home: LanShareSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.hub_outlined));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}

LanShareViewModel _createViewModel(FakeLanShareSettings settings) =>
    LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: FakeLanSecurityService(),
      storageService: FakeLanStorageService(),
      transferService: FakeLanTransferService(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
