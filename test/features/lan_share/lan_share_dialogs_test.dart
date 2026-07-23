import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/data/database/app_database.dart';
import 'package:ssh_mobile/features/lan_share/views/lan_share_screen.dart';
import 'package:ssh_mobile/features/lan_share/viewmodels/lan_share_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/lan_share/lan_discovery_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';

class _FakeAppSettings extends AppSettings {
  @override
  bool get isEnglish => false;
}

class _FakeLanShareViewModel extends LanShareViewModel {
  _FakeLanShareViewModel({
    required super.discoveryService,
    required super.transferService,
    required super.storageService,
    required super.securityService,
    required super.historyDao,
    required super.appSettings,
  });

  @override
  String? get webShareUrl => 'http://192.168.1.100:53319/?pin=123456';

  @override
  bool get webShareUseHttps => false;
}

void main() {
  testWidgets(
    'WebShareDialogContent renders without vertical overflow on constrained screen',
    (tester) async {
      final sec = LanSecurityService();
      final stor = LanStorageService();
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(() => db.close());

      final vm = _FakeLanShareViewModel(
        discoveryService: LanDiscoveryService(
          currentDeviceId: 'dev1',
          currentDeviceAlias: 'Alias',
        ),
        transferService: LanTransferService(
          securityService: sec,
          storageService: stor,
          currentDeviceId: 'dev1',
        ),
        storageService: stor,
        securityService: sec,
        historyDao: LanHistoryDao(db),
        appSettings: _FakeAppSettings(),
      );
      final strings = AppStrings(AppLanguage.zh);

      // Set constrained vertical screen size (350 height) to verify SingleChildScrollView prevents RenderFlex bottom overflow
      tester.view.physicalSize = const Size(400, 350);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: WebShareDialogContent(vm: vm, strings: strings),
            ),
          ),
        ),
      );

      // Expect no exception during layout
      expect(tester.takeException(), isNull);
      expect(find.byType(WebShareDialogContent), findsOneWidget);
    },
  );
}
