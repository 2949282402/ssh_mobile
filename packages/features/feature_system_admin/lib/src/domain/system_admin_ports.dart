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

/// System Admin 允许执行的远端命令快照。
///
/// 动态参数只能通过 [argv] 提供，App adapter 负责逐项安全编码。只有完全由
/// Feature 持有、没有动态输入的脚本才可使用 [shell]。敏感输入只存在于
/// [standardInputBytes]，不得复制到命令文本、日志或异常。
final class SystemAdminCommand {
  SystemAdminCommand._({
    required this.executable,
    required List<String> arguments,
    required this.shellScript,
    required Uint8List? standardInputBytes,
  }) : arguments = List<String>.unmodifiable(arguments),
       _standardInputBytes = standardInputBytes == null
           ? null
           : Uint8List.fromList(standardInputBytes);

  /// 所有 stdout/stderr 合计的统一硬上限。
  static const int maxOutputBytes = 2 * 1024 * 1024;

  /// stdin 的硬上限；当前只用于 `chpasswd` 的单条受控记录。
  static const int maxInputBytes = 16 * 1024;

  /// 创建 argv 命令；参数不会经过 shell 拼接。
  factory SystemAdminCommand.argv(
    String executable, {
    List<String> arguments = const <String>[],
    Uint8List? standardInputBytes,
  }) {
    if (executable.trim().isEmpty) {
      throw ArgumentError.value(executable, 'executable', 'must not be empty');
    }
    if (standardInputBytes != null &&
        standardInputBytes.length > maxInputBytes) {
      throw ArgumentError.value(
        standardInputBytes.length,
        'standardInputBytes',
        'exceeds the System Admin input limit',
      );
    }
    return SystemAdminCommand._(
      executable: executable,
      arguments: arguments,
      shellScript: null,
      standardInputBytes: standardInputBytes,
    );
  }

  /// 创建没有任何动态输入的固定 shell 脚本。
  factory SystemAdminCommand.shell(String script) {
    if (script.trim().isEmpty) {
      throw ArgumentError.value(script, 'script', 'must not be empty');
    }
    return SystemAdminCommand._(
      executable: null,
      arguments: const <String>[],
      shellScript: script,
      standardInputBytes: null,
    );
  }

  final String? executable;
  final List<String> arguments;
  final String? shellScript;
  final Uint8List? _standardInputBytes;

  /// 返回 stdin 的短生命周期副本，避免调用方修改命令快照。
  Uint8List? get standardInputBytes {
    final bytes = _standardInputBytes;
    return bytes == null ? null : Uint8List.fromList(bytes);
  }
}

/// 远端输出超过统一上限时返回的稳定错误；不包含远端输出或命令文本。
final class SystemAdminOutputLimitException implements Exception {
  const SystemAdminOutputLimitException({required this.maxBytes});

  final int maxBytes;

  @override
  String toString() =>
      'System Admin command output exceeded the $maxBytes-byte limit.';
}

/// 管理命令在统一 deadline 内未完成时返回的稳定错误。
final class SystemAdminCommandTimeoutException implements Exception {
  const SystemAdminCommandTimeoutException();

  @override
  String toString() => 'System Admin command timed out.';
}

/// 管理命令被 Route/用户取消时返回的稳定错误。
final class SystemAdminCommandCancelledException implements Exception {
  const SystemAdminCommandCancelledException();

  @override
  String toString() => 'System Admin command was cancelled.';
}

/// 管理 SSH 在 deadline 内未建立时返回的稳定错误。
final class SystemAdminConnectionTimeoutException implements Exception {
  const SystemAdminConnectionTimeoutException();

  @override
  String toString() => 'System Admin SSH acquisition timed out.';
}

/// 已通过 root 校验的不可变目标和管理会话 generation。
final class SystemAdminSessionTarget {
  const SystemAdminSessionTarget({
    required this.binding,
    required this.generation,
  });

  final SshTargetBinding binding;
  final int generation;

  String get connectionId => binding.id;

  bool matches(SystemAdminSessionTarget other) =>
      generation == other.generation &&
      binding.fingerprint == other.binding.fingerprint;
}

/// 管理会话中的专用短生命周期 SSH Lease。
abstract interface class SystemAdminSshLeasePort {
  /// 实际建立并通过 Host Key 校验的不可变目标。
  SshTargetBinding get targetBinding;

  bool get isReleased;

  Future<RemoteCommandResult> run(
    SystemAdminCommand command, {
    required Duration timeout,
  });

  void cancelActiveCommands();

  /// 交还该 Feature 当前持有的管理 Lease；重复调用安全。
  Future<void> release();
}

/// App Shell 提供的管理 SSH 连接能力。
abstract interface class SystemAdminSshPort {
  Future<SystemAdminSshLeasePort> acquire(
    SshTargetBinding target, {
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
