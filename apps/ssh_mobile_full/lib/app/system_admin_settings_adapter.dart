// System Admin Feature 的 App 设置与本地化投影。

import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:flutter/foundation.dart';

import '../services/app_settings.dart';

/// 将 AppSettings/AppStrings 适配为 Feature 的最小设置 Port。
final class AppSystemAdminSettingsAdapter extends ChangeNotifier
    implements admin.SystemAdminSettingsPort {
  /// 创建不拥有 AppSettings 的设置适配器。
  AppSystemAdminSettingsAdapter(this._settings) {
    _settings.addListener(notifyListeners);
  }

  final AppSettings _settings;

  @override
  admin.SystemAdminLanguage get language => _settings.language == AppLanguage.en
      ? admin.SystemAdminLanguage.en
      : admin.SystemAdminLanguage.zh;

  @override
  bool get isEnglish => language == admin.SystemAdminLanguage.en;

  @override
  admin.SystemAdminStrings get strings =>
      AppSystemAdminStrings(AppStrings(_settings.language));

  @override
  void dispose() {
    _settings.removeListener(notifyListeners);
    super.dispose();
  }
}

/// Feature 文案到全局 AppStrings 的只读映射。
final class AppSystemAdminStrings implements admin.SystemAdminStrings {
  /// 创建一份语言快照；不持有设置或其它资源。
  const AppSystemAdminStrings(this._strings);

  final AppStrings _strings;

  @override
  admin.SystemAdminLanguage get language => _strings.language == AppLanguage.en
      ? admin.SystemAdminLanguage.en
      : admin.SystemAdminLanguage.zh;

  @override
  String get activeProcesses => _strings.activeProcesses;
  @override
  String get activeSessions => _strings.activeSessions;
  @override
  String get actionConfirm => _strings.actionConfirm;
  @override
  String get addConnection => _strings.addConnection;
  @override
  String get adminConnectAsRoot => _strings.adminConnectAsRoot;
  @override
  String get adminConnectionFailed => _strings.adminConnectionFailed;
  @override
  String get adminLinuxManagementHint => _strings.adminLinuxManagementHint;
  @override
  String get adminRootAccess => _strings.adminRootAccess;
  @override
  String get adminSelectServer => _strings.adminSelectServer;
  @override
  String get administrator => _strings.administrator;
  @override
  String get applications => _strings.applications;
  @override
  String get backToHome => _strings.backToHome;
  @override
  String get cancel => _strings.cancel;
  @override
  String get changePassword => _strings.changePassword;
  @override
  String get changePasswordTitle => _strings.changePasswordTitle;
  @override
  String get close => _strings.close;
  @override
  String get collapseServerList => _strings.collapseServerList;
  @override
  String get connected => _strings.connected;
  @override
  String get connectingEllipsis => _strings.connectingEllipsis;
  @override
  String get createUser => _strings.createUser;
  @override
  String get enterNewPassword => _strings.enterNewPassword;
  @override
  String get expandServerList => _strings.expandServerList;
  @override
  String get grantSudo => _strings.grantSudo;
  @override
  String get killAction => _strings.killAction;
  @override
  String get killSession => _strings.killSession;
  @override
  String killSessionConfirm(String username, String tty) =>
      _strings.killSessionConfirm(username, tty);
  @override
  String get listeningPorts => _strings.listeningPorts;
  @override
  String get lockUser => _strings.lockUser;
  @override
  String get loginShell => _strings.loginShell;
  @override
  String get memoryUsed => _strings.memoryUsed;
  @override
  String get monitor => _strings.monitor;
  @override
  String get noConnections => _strings.noConnections;
  @override
  String get normalUser => _strings.normalUser;
  @override
  String get notConnected => _strings.notConnected;
  @override
  String get nonLinuxMsg => _strings.nonLinuxMsg;
  @override
  String get omServers => _strings.omServers;
  @override
  String get passwordChangedSuccess => _strings.passwordChangedSuccess;
  @override
  String get refresh => _strings.refresh;
  @override
  String get reorderServer => _strings.reorderServer;
  @override
  String get reconnectAsRootMsg => _strings.reconnectAsRootMsg;
  @override
  String get rebootServer => _strings.rebootServer;
  @override
  String get revokeSudo => _strings.revokeSudo;
  @override
  String get rootRequiredMsg => _strings.rootRequiredMsg;
  @override
  String get save => _strings.save;
  @override
  String get searchService => _strings.searchService;
  @override
  String get selectServerToManage => _strings.selectServerToManage;
  @override
  String get serviceDisable => _strings.serviceDisable;
  @override
  String get serviceEnable => _strings.serviceEnable;
  @override
  String get serviceRestart => _strings.serviceRestart;
  @override
  String get serviceStart => _strings.serviceStart;
  @override
  String get serviceStop => _strings.serviceStop;
  @override
  String get shutdownServer => _strings.shutdownServer;
  @override
  String get statusLocked => _strings.statusLocked;
  @override
  String get storageUsed => _strings.storageUsed;
  @override
  String get sudoStatus => _strings.sudoStatus;
  @override
  String get systemOmAdmin => _strings.systemOmAdmin;
  @override
  String get systemPower => _strings.systemPower;
  @override
  String get systemPowerHint => _strings.systemPowerHint;
  @override
  String get systemServices => _strings.systemServices;
  @override
  String get unlockUser => _strings.unlockUser;
  @override
  String get usageStats => _strings.usageStats;
  @override
  String get userAccounts => _strings.userAccounts;
  @override
  String get userCreatedSuccess => _strings.userCreatedSuccess;
  @override
  String get username => _strings.username;
  @override
  String get verifyingPrivilege => _strings.verifyingPrivilege;
  @override
  String get viewHomeDir => _strings.viewHomeDir;
}
