// System Admin Feature 的跨层 Port。
//
// 这些接口隔离 App Shell 的 Storage、SSH 客户端、监控实现和 UI 文案，
// 使管理 Feature 能在没有真实网络、数据库或其他 Feature 实现的测试中运行。

import 'package:flutter/foundation.dart';
import 'package:connection_core/connection_core.dart';
import 'package:ssh_core/ssh_core.dart';

/// System Admin 页面使用的语言枚举。
enum SystemAdminLanguage { zh, en }

/// 连接目录的最小能力；具体 Repository 由 App Shell 持有。
abstract interface class SystemAdminConnectionCatalogPort
    implements Listenable {
  bool get isInitialized;
  List<ConnectionConfig> get connections;

  ConnectionConfig? connectionById(String id);

  Future<void> reorderConnections(int oldIndex, int newIndex);
}

/// System Admin 需要的最小文案集合，避免依赖 AppSettings/AppStrings。
abstract interface class SystemAdminStrings {
  SystemAdminLanguage get language;

  String get activeProcesses;
  String get activeSessions;
  String get actionConfirm;
  String get addConnection;
  String get adminConnectAsRoot;
  String get adminConnectionFailed;
  String get adminLinuxManagementHint;
  String get adminRootAccess;
  String get adminSelectServer;
  String get administrator;
  String get applications;
  String get backToHome;
  String get cancel;
  String get changePassword;
  String get changePasswordTitle;
  String get close;
  String get collapseServerList;
  String get connected;
  String get connectingEllipsis;
  String get createUser;
  String get enterNewPassword;
  String get expandServerList;
  String get grantSudo;
  String get killAction;
  String get killSession;
  String killSessionConfirm(String username, String tty);
  String get listeningPorts;
  String get lockUser;
  String get loginShell;
  String get memoryUsed;
  String get monitor;
  String get noConnections;
  String get normalUser;
  String get notConnected;
  String get nonLinuxMsg;
  String get omServers;
  String get passwordChangedSuccess;
  String get refresh;
  String get reorderServer;
  String get reconnectAsRootMsg;
  String get rebootServer;
  String get revokeSudo;
  String get rootRequiredMsg;
  String get save;
  String get searchService;
  String get selectServerToManage;
  String get serviceDisable;
  String get serviceEnable;
  String get serviceRestart;
  String get serviceStart;
  String get serviceStop;
  String get shutdownServer;
  String get statusLocked;
  String get storageUsed;
  String get sudoStatus;
  String get systemOmAdmin;
  String get systemPower;
  String get systemPowerHint;
  String get systemServices;
  String get unlockUser;
  String get usageStats;
  String get userAccounts;
  String get userCreatedSuccess;
  String get username;
  String get verifyingPrivilege;
  String get viewHomeDir;
}

/// 设置和文案的最小可观察 Port。
abstract interface class SystemAdminSettingsPort implements Listenable {
  SystemAdminLanguage get language;
  bool get isEnglish => language == SystemAdminLanguage.en;
  SystemAdminStrings get strings;
}

/// 管理会话中的一次性命令执行能力。
abstract interface class SystemAdminSshSessionPort {
  Future<RemoteCommandResult> run(String command, {required Duration timeout});

  void cancelActiveCommands();

  /// 关闭该 Feature 当前持有的管理会话。
  void close();
}

/// App Shell 提供的管理 SSH 连接能力。
abstract interface class SystemAdminSshPort {
  Future<SystemAdminSshSessionPort> connect(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  });
}

/// 管理命令日志能力；Feature 不访问全局日志单例。
abstract interface class SystemAdminLoggerPort {
  void info(String message, {String? details});
  void warning(String message, {String? details});
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  });
}

/// System Admin 请求 Host Key 确认 UI 的能力。
abstract interface class SystemAdminHostKeyConfirmationPort {
  Future<bool> confirm(SshHostKeyPromptRequest request);
}

/// 家目录浏览只需要的 SFTP 文件快照。
final class SystemAdminFileEntry {
  const SystemAdminFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.sizeLabel = '',
    this.modifiedLabel,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final String sizeLabel;
  final String? modifiedLabel;
}

/// 家目录浏览能力；真正的传输/缓存 Owner 仍在 SFTP/App Scope。
abstract interface class SystemAdminFileBrowserPort {
  Future<List<SystemAdminFileEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  );
}
