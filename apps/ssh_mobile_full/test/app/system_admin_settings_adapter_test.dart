// System Admin 设置/文案投影的独立适配器测试。

import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/app/system_admin_settings_adapter.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'language changes propagate and disposal detaches the listener',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = AppSettings();
      final adapter = AppSystemAdminSettingsAdapter(settings);
      var notifications = 0;
      adapter.addListener(() => notifications++);

      expect(adapter.language, admin.SystemAdminLanguage.zh);
      expect(adapter.isEnglish, isFalse);
      await settings.toggleLanguage();
      expect(adapter.language, admin.SystemAdminLanguage.en);
      expect(adapter.isEnglish, isTrue);
      expect(notifications, 1);

      adapter.dispose();
      await settings.toggleLanguage();
      expect(notifications, 1);
      settings.dispose();
    },
  );

  test('all System Admin strings are projected from one language snapshot', () {
    final strings = AppSystemAdminStrings(AppStrings(AppLanguage.en));

    expect(strings.language, admin.SystemAdminLanguage.en);
    final values = <String>[
      strings.activeProcesses,
      strings.activeSessions,
      strings.actionConfirm,
      strings.addConnection,
      strings.adminConnectAsRoot,
      strings.adminConnectionFailed,
      strings.adminLinuxManagementHint,
      strings.adminRootAccess,
      strings.adminSelectServer,
      strings.administrator,
      strings.applications,
      strings.backToHome,
      strings.cancel,
      strings.changePassword,
      strings.changePasswordTitle,
      strings.close,
      strings.collapseServerList,
      strings.connected,
      strings.connectingEllipsis,
      strings.createUser,
      strings.enterNewPassword,
      strings.expandServerList,
      strings.grantSudo,
      strings.killAction,
      strings.killSession,
      strings.killSessionConfirm('operator', 'pts/1'),
      strings.listeningPorts,
      strings.lockUser,
      strings.loginShell,
      strings.memoryUsed,
      strings.monitor,
      strings.noConnections,
      strings.normalUser,
      strings.notConnected,
      strings.nonLinuxMsg,
      strings.omServers,
      strings.passwordChangedSuccess,
      strings.refresh,
      strings.reorderServer,
      strings.reconnectAsRootMsg,
      strings.rebootServer,
      strings.revokeSudo,
      strings.rootRequiredMsg,
      strings.save,
      strings.searchService,
      strings.selectServerToManage,
      strings.serviceDisable,
      strings.serviceEnable,
      strings.serviceRestart,
      strings.serviceStart,
      strings.serviceStop,
      strings.shutdownServer,
      strings.statusLocked,
      strings.storageUsed,
      strings.sudoStatus,
      strings.systemOmAdmin,
      strings.systemPower,
      strings.systemPowerHint,
      strings.systemServices,
      strings.unlockUser,
      strings.usageStats,
      strings.userAccounts,
      strings.userCreatedSuccess,
      strings.username,
      strings.verifyingPrivilege,
      strings.viewHomeDir,
    ];

    expect(values, everyElement(isNotEmpty));
  });
}
