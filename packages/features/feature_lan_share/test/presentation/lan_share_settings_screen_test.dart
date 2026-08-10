import 'package:feature_lan_share/feature_lan_share.dart';
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
