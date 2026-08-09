// v1 LAN 设置页面 Provider 范围回归测试。

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/lan_share/viewmodels/lan_share_viewmodel.dart';
import 'package:ssh_mobile/features/lan_share/views/lan_share_settings_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/lan_share/lan_discovery_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';
import 'package:ssh_mobile/services/network/network_models.dart';

class _FakeLanSecurityService extends Fake implements LanSecurityService {}

class _FakeLanTransferService extends Fake implements LanTransferService {}

class _FakeLanDiscoveryService extends Fake implements LanDiscoveryService {
  @override
  Future<NetworkResult<void>> stopDiscovery() async =>
      const NetworkSuccess<void>(null);
}

class _FakeLanHistoryDao extends Fake
    implements feature_lan_share.LanHistoryDao {}

class _FakeLanStorageService extends Fake implements LanStorageService {}

/// 执行 LAN 设置页面 Provider 范围组件测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late LanShareViewModel viewModel;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    appSettings = AppSettings();
    await appSettings.init();
    viewModel = LanShareViewModel(
      discoveryService: _FakeLanDiscoveryService(),
      transferService: _FakeLanTransferService(),
      securityService: _FakeLanSecurityService(),
      historyDao: _FakeLanHistoryDao(),
      storageService: _FakeLanStorageService(),
      appSettings: appSettings,
      ownsRuntime: false,
    );
  });

  tearDown(() {
    viewModel.dispose();
    appSettings.dispose();
  });

  testWidgets('renders LAN settings when a LanShareViewModel is provided', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<LanShareViewModel>.value(
        value: viewModel,
        child: const MaterialApp(home: LanShareSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LanShareSettingsScreen), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets('the unwrapped screen throws ProviderNotFoundException', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LanShareSettingsScreen()));
    // Regression guard for the crash fixed by wrapping the settings route in
    // LanShareFeatureScope: without a provided LanShareViewModel the screen
    // must fail loudly instead of rendering.
    expect(tester.takeException(), isA<ProviderNotFoundException>());
  });
}
