// Terminal-only App 的 App Shell Port 适配器。
//
// 这些实现只保存该编译切片需要的内存状态和 Core Repository 引用，不
// 创建全局 Service，也不把 Full App 的设置、日志或网络实现复制进来。

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

/// Terminal-only App 的最小设置 Port。
final class TerminalOnlySettings extends ChangeNotifier
    implements TerminalSettingsPort {
  /// 使用中文和默认终端外观创建设置。
  TerminalOnlySettings();

  @override
  Object language = AppLanguage.zh;

  @override
  bool isDarkMode = false;

  @override
  bool oledDark = false;

  @override
  String terminalThemeId = 'default';

  @override
  String terminalFontFamily = '';

  @override
  void toggleTheme() {
    isDarkMode = !isDarkMode;
    notifyListeners();
  }

  @override
  Future<void> setTerminalThemeId(String id) async {
    terminalThemeId = id;
    notifyListeners();
  }

  @override
  Future<void> setTerminalFontFamily(String family) async {
    terminalFontFamily = family;
    notifyListeners();
  }
}

/// Terminal-only App 的快捷命令 Port。
final class TerminalOnlyShortcuts extends ChangeNotifier
    implements TerminalShortcutPort {
  /// 使用 Terminal 页面内置快捷键的默认顺序。
  TerminalOnlyShortcuts();

  static const List<String> _defaultQuickCommandIds = <String>[
    'tab',
    'esc',
    'enter',
    'bksp',
    'up',
    'down',
    'left',
    'right',
    'ctrl_c',
  ];

  List<String> _quickCommandIds = List<String>.unmodifiable(
    _defaultQuickCommandIds,
  );
  List<TerminalShortcutCommand> _customCommands = const [];
  int _orderVersion = 0;

  @override
  int get orderVersion => _orderVersion;

  @override
  List<TerminalShortcutCommand> get customCommands => _customCommands;

  @override
  List<String> get quickCommandIds => _quickCommandIds;

  @override
  List<TerminalShortcutCommand> sortByUsage(
    List<TerminalShortcutCommand> commands,
  ) => List<TerminalShortcutCommand>.unmodifiable(commands);

  @override
  Future<void> recordUse(String id) async {}

  @override
  Future<void> reorderCommands(List<String> ids) async {
    _quickCommandIds = List<String>.unmodifiable(ids);
    _orderVersion++;
    notifyListeners();
  }

  @override
  Future<void> setQuickCommandIds(Iterable<String> ids) async {
    _quickCommandIds = List<String>.unmodifiable(ids);
    notifyListeners();
  }

  @override
  Future<void> resetQuickCommandIds() async {
    _quickCommandIds = List<String>.unmodifiable(_defaultQuickCommandIds);
    _orderVersion++;
    notifyListeners();
  }

  @override
  Future<void> addCustomCommand(String label, String code) async {
    final id = 'custom-${_customCommands.length + 1}';
    _customCommands = List<TerminalShortcutCommand>.unmodifiable([
      ..._customCommands,
      TerminalShortcutCommand(id: id, label: label, code: code, custom: true),
    ]);
    notifyListeners();
  }

  @override
  Future<void> removeCustomCommand(String id) async {
    _customCommands = List<TerminalShortcutCommand>.unmodifiable(
      _customCommands.where((command) => command.id != id),
    );
    notifyListeners();
  }
}

/// 将 Connection Core Repository 暴露为 Terminal 的连接 Port。
final class TerminalOnlyConnections implements TerminalConnectionPort {
  /// 创建只读连接快照适配器。
  const TerminalOnlyConnections({this.repository, required this.terminal});

  /// App Scope Connection Repository。
  final ConnectionRepository? repository;

  /// Terminal-only 的 SSH Capability。
  final SshTerminalCapability terminal;

  @override
  TerminalConnectionInfo? getConnection(String connectionId) {
    final config = repository?.getConnection(connectionId);
    if (config == null) return null;
    return TerminalConnectionInfo(
      id: config.id,
      name: config.name,
      host: config.host,
      port: config.port,
      username: config.username,
    );
  }

  @override
  String defaultDisplayNameForConnection(String connectionId) {
    return repository?.getConnection(connectionId)?.name ?? connectionId;
  }

  @override
  Future<String?> openSession(String connectionId, {String? displayName}) {
    return terminal.openSession(connectionId, displayName: displayName);
  }

  @override
  Future<void> openConnectionEditor(
    String connectionId, {
    bool isNew = false,
  }) async {}
}

/// 将 Core Logger 转为 Terminal 的脱敏日志 Port。
final class TerminalOnlyLogger implements TerminalLoggerPort {
  /// 创建日志适配器。
  const TerminalOnlyLogger(this.logger);

  /// Terminal-only App 的唯一 Logger Owner。
  final AppLogger logger;

  @override
  void info(String message) => _write(LogLevel.info, message);

  @override
  void warning(String message, {Object? error, StackTrace? stackTrace}) {
    _write(LogLevel.warning, message, error: error, stackTrace: stackTrace);
  }

  @override
  void error(String message, {Object? error, StackTrace? stackTrace}) {
    _write(LogLevel.error, message, error: error, stackTrace: stackTrace);
  }

  void _write(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    logger.log(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        source: 'terminal_app',
        message: message,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
}
