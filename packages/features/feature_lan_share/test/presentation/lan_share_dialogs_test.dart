import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets('WebShare dialog content remains usable on a short viewport', (
    tester,
  ) async {
    final settings = FakeLanShareSettings();
    final viewModel = LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(
        activeWebShare: true,
        shareUrl: 'https://192.168.1.100:53319/?pin=123456',
      ),
      securityService: FakeLanSecurityService(),
      storageService: FakeLanStorageService(),
      transferService: FakeLanTransferService(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
    addTearDown(() {
      viewModel.dispose();
      settings.dispose();
    });

    tester.view.physicalSize = const Size(400, 350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: WebShareDialogContent(
              vm: viewModel,
              strings: settings.strings,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(WebShareDialogContent), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
