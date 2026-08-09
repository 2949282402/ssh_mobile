// v1 LAN WebShare 对话框渲染测试。

import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/lan_share/views/lan_share_screen.dart';
import 'package:ssh_mobile/features/lan_share/viewmodels/lan_share_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/lan_share/lan_discovery_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';

/// 为 WebShare 对话框提供固定语言设置的测试对象。
class _FakeAppSettings extends AppSettings {
  /// 返回中文界面设置。
  @override
  bool get isEnglish => false;
}

/// 为 WebShare 对话框提供本地依赖的测试 ViewModel。
class _FakeLanShareViewModel extends LanShareViewModel {
  /// 创建固定 WebShare 地址的测试 ViewModel。
  _FakeLanShareViewModel({
    required super.discoveryService,
    required super.transferService,
    required super.storageService,
    required super.securityService,
    required super.historyDao,
    required super.appSettings,
  });

  /// 返回测试用的 HTTPS WebShare 地址。
  @override
  String? get webShareUrl => 'https://192.168.1.100:53319/?pin=123456';
}

/// 执行 LAN WebShare 对话框的布局回归测试。
void main() {
  testWidgets(
    'WebShareDialogContent renders without vertical overflow on constrained screen',
    (tester) async {
      final sec = LanSecurityService();
      final stor = LanStorageService();
      final db = feature_lan_share.LanShareDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.dispose);

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
        historyDao: feature_lan_share.LanHistoryDao(db),
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
