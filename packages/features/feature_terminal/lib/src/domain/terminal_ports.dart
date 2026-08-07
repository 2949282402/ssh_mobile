// Terminal 与 App Shell、SSH Infrastructure 的依赖 Port。
//
// Port 只描述能力，不暴露 App 的具体 Service 类型；这样 Terminal 可以在
// 独立 Package 中测试，也不会反向依赖 App 或其他 Feature。

import 'package:flutter/foundation.dart';
import 'terminal_models.dart';

/// Terminal 页面所需的设置快照和写入能力。
abstract interface class TerminalSettingsPort implements Listenable {
  /// 当前语言对象；Package 不要求 App 使用特定的枚举类型。
  Object get language;

  bool get isDarkMode;
  bool get oledDark;
  String get terminalThemeId;
  String get terminalFontFamily;

  /// 切换 App 当前主题。
  void toggleTheme();

  /// 保存终端配色方案。
  Future<void> setTerminalThemeId(String id);

  /// 保存自定义终端字体。
  Future<void> setTerminalFontFamily(String family);
}

/// 终端页面显示的连接快照。
final class TerminalConnectionInfo {
  /// 创建连接显示信息。
  const TerminalConnectionInfo({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;

  /// 不包含密码或密钥的可展示端点。
  String get endpoint => '$username@$host:$port';
}

/// Terminal 连接弹窗和窗口导航所需的 App Capability。
abstract interface class TerminalConnectionPort {
  TerminalConnectionInfo? getConnection(String connectionId);

  String defaultDisplayNameForConnection(String connectionId);

  /// 打开会话；Host Key UI 回调由 App 适配器在内部绑定。
  Future<String?> openSession(String connectionId, {String? displayName});

  /// 跳转到新增或编辑连接页面。
  Future<void> openConnectionEditor(String connectionId, {bool isNew});
}

/// 快捷命令的不可变 Package 模型。
final class TerminalShortcutCommand {
  /// 创建快捷命令。
  const TerminalShortcutCommand({
    required this.id,
    required this.label,
    required this.code,
    this.custom = false,
  });

  final String id;
  final String label;
  final String code;
  final bool custom;
}

/// Terminal 快捷命令能力。
abstract interface class TerminalShortcutPort implements Listenable {
  int get orderVersion;
  List<TerminalShortcutCommand> get customCommands;
  List<String> get quickCommandIds;
  List<TerminalShortcutCommand> sortByUsage(
    List<TerminalShortcutCommand> commands,
  );
  Future<void> recordUse(String id);
  Future<void> reorderCommands(List<String> ids);
  Future<void> setQuickCommandIds(Iterable<String> ids);
  Future<void> resetQuickCommandIds();
  Future<void> addCustomCommand(String label, String code);
  Future<void> removeCustomCommand(String id);
}

/// 页面日志 Port；实现必须过滤敏感数据后再写入日志。
abstract interface class TerminalLoggerPort {
  void info(String message);

  void warning(String message, {Object? error, StackTrace? stackTrace});

  void error(String message, {Object? error, StackTrace? stackTrace});
}

/// Terminal 原始输出历史所需的数据保护能力。
///
/// 加密实现仍由 App Infrastructure 提供；Terminal 只负责有界缓存、分块
/// 写入和串行化，不直接访问平台密钥或静态安全服务。
abstract interface class TerminalHistoryOutputProtector {
  String get encryptedPrefix;

  bool isEncrypted(String value);

  Future<String> encryptString(String value);

  Future<String> decryptString(String value);
}

/// Terminal 历史记录仓储契约。
abstract interface class TerminalHistoryRepository {
  Future<List<TerminalHistoryRecord>> loadRecords();

  Future<void> saveRecord(TerminalHistoryRecord record);

  Future<void> removeRecord(String sessionId);

  Future<void> replaceAll(Iterable<TerminalHistoryRecord> records);
}
