// Terminal Package 测试替身。
//
// 这些 Fake 只实现测试所需的 Port/Capability，不创建真实 SSH、数据库或
// 平台资源；测试可以据此验证 ViewModel 和页面的生命周期行为。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

import 'package:feature_terminal/feature_terminal.dart';

/// 可控的终端设置 Fake。
final class FakeTerminalSettings extends ChangeNotifier
    implements TerminalSettingsPort {
  FakeTerminalSettings({this.language = 'zh'});

  @override
  Object language;

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

/// 可控的快捷命令 Fake。
final class FakeTerminalShortcuts extends ChangeNotifier
    implements TerminalShortcutPort {
  @override
  int orderVersion = 0;

  @override
  List<TerminalShortcutCommand> customCommands = const [];

  @override
  List<String> quickCommandIds = const [
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

  @override
  List<TerminalShortcutCommand> sortByUsage(
    List<TerminalShortcutCommand> commands,
  ) => List.unmodifiable(commands);

  @override
  Future<void> recordUse(String id) async {}

  @override
  Future<void> reorderCommands(List<String> ids) async {
    orderVersion++;
    notifyListeners();
  }

  @override
  Future<void> setQuickCommandIds(Iterable<String> ids) async {
    quickCommandIds = List.unmodifiable(ids);
    notifyListeners();
  }

  @override
  Future<void> resetQuickCommandIds() async {}

  @override
  Future<void> addCustomCommand(String label, String code) async {}

  @override
  Future<void> removeCustomCommand(String id) async {}
}

/// 可记录输入和会话状态的 SSH Terminal Capability Fake。
final class FakeTerminalCapability implements SshTerminalCapability {
  FakeTerminalCapability({List<SshTerminalSession> sessions = const []})
    : _sessions = List<SshTerminalSession>.of(sessions);

  final List<SshTerminalSession> _sessions;
  final Map<String, String> _renamedSessions = <String, String>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<String> sentData = <String>[];
  final List<String> disconnectedSessionIds = <String>[];
  bool ensureSessionConnectedResult = false;
  Future<bool> Function(String sessionId, String connectionId)?
  ensureSessionConnectedHandler;
  String? lastOpenedConnectionId;
  Future<String> Function(String sessionId)? historyLoader;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  List<SshTerminalSession> get sessions =>
      List.unmodifiable(_sessions.map(_withRenamedDisplayName));

  @override
  SshTerminalSession? getSession(String sessionId) {
    for (final session in _sessions) {
      if (session.id == sessionId) return _withRenamedDisplayName(session);
    }
    return null;
  }

  @override
  String? errorMessage;

  @override
  Future<String> loadSessionHistoryText(String sessionId) async =>
      historyLoader != null
      ? historyLoader!(sessionId)
      : getSession(sessionId)?.outputText ?? '';

  @override
  Future<bool> ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async => ensureSessionConnectedHandler != null
      ? ensureSessionConnectedHandler!(sessionId, connectionId)
      : ensureSessionConnectedResult;

  @override
  void setSessionFontSize(String sessionId, double fontSize) {}

  @override
  void sendData(String sessionId, String data) {
    sentData.add(data);
  }

  @override
  void resizeTerminal(String sessionId, int width, int height) {}

  @override
  Future<void> disconnectSession(String sessionId) async {
    disconnectedSessionIds.add(sessionId);
  }

  @override
  Future<void> disconnect() async {}

  @override
  bool isSessionNameAvailable(String name) =>
      name.trim().isNotEmpty &&
      _sessions.every(
        (session) =>
            _withRenamedDisplayName(session).displayName.toLowerCase() !=
            name.trim().toLowerCase(),
      );

  @override
  bool renameSession(String sessionId, String name) {
    if (getSession(sessionId) == null ||
        _sessions.any(
          (session) =>
              session.id != sessionId &&
              _withRenamedDisplayName(session).displayName.toLowerCase() ==
                  name.trim().toLowerCase(),
        )) {
      return false;
    }
    _renamedSessions[sessionId] = name.trim();
    emitChange();
    return true;
  }

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
  }) async {
    lastOpenedConnectionId = connectionId;
    return null;
  }

  @override
  Future<bool> ensureConnected(String connectionId) async => false;

  /// 让页面测试触发一次会话变更通知。
  void emitChange() => _changes.add(null);

  /// 关闭 Fake 的通知资源。
  Future<void> close() => _changes.close();

  SshTerminalSession _withRenamedDisplayName(SshTerminalSession session) {
    final displayName = _renamedSessions[session.id];
    if (displayName == null) return session;
    return SshTerminalSession(
      id: session.id,
      connectionId: session.connectionId,
      connectionName: session.connectionName,
      displayName: displayName,
      tmuxSessionName: session.tmuxSessionName,
      tmuxAutoDeleteSeconds: session.tmuxAutoDeleteSeconds,
      fontSize: session.fontSize,
      state: session.state,
      errorMessage: session.errorMessage,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      output: session.output,
      outputText: session.outputText,
      estimatedMemoryBytes: session.estimatedMemoryBytes,
    );
  }
}

/// 仅包装 Terminal Capability 的 SSH Manager Fake。
final class FakeSshSessionManager implements SshSessionManager {
  FakeSshSessionManager(this.terminal);

  final FakeTerminalCapability terminal;

  @override
  SshTerminalCapability get terminalCapability => terminal;

  @override
  bool initialized = true;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<SshSessionLease> acquire({
    required String sessionId,
    required Future<SshSession> Function() create,
  }) {
    throw UnsupportedError('The terminal tests do not acquire SSH leases.');
  }

  @override
  Future<void> close() => terminal.close();
}

/// 测试用日志 Port，记录消息但不输出敏感详情。
final class FakeTerminalLogger implements TerminalLoggerPort {
  final List<String> infos = <String>[];
  final List<String> errors = <String>[];
  final List<String> warnings = <String>[];

  @override
  void info(String message) {
    infos.add(message);
  }

  @override
  void warning(String message, {Object? error, StackTrace? stackTrace}) {
    warnings.add(message);
  }

  @override
  void error(String message, {Object? error, StackTrace? stackTrace}) {
    errors.add(message);
  }
}

/// 创建测试用终端会话快照。
SshTerminalSession buildTerminalSession({
  required String id,
  required String connectionId,
  required String connectionName,
  required String displayName,
  required SshConnectionState state,
  String? errorMessage,
  String? tmuxSessionName,
}) {
  return SshTerminalSession(
    id: id,
    connectionId: connectionId,
    connectionName: connectionName,
    displayName: displayName,
    tmuxSessionName: tmuxSessionName,
    tmuxAutoDeleteSeconds: tmuxSessionName == null ? null : 600,
    fontSize: SshSession.defaultTerminalFontSize,
    state: state,
    errorMessage: errorMessage,
    createdAt: DateTime(2026, 7, 15, 9, 30),
    updatedAt: DateTime(2026, 7, 15, 10),
    output: const Stream<String>.empty(),
    outputText: '',
    estimatedMemoryBytes: 0,
  );
}
