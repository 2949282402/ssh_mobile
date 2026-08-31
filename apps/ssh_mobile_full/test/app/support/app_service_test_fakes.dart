// App 服务层共享测试替身：设置、连接目录、日志与快捷命令。

import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart'
    as feature_connection;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/shortcut_command_service.dart';

final class FakeAppSettings extends Fake implements AppSettings {
  @override
  AppLanguage language = AppLanguage.en;
  @override
  bool isDarkMode = false;
  @override
  bool oledDark = false;
  @override
  String terminalThemeId = 'default';
  @override
  String terminalFontFamily = 'monospace';
  @override
  int sftpDownloadLimitBytes = 64 * 1024;
  @override
  int sftpTextPreviewLimitBytes = 128 * 1024;
  @override
  int sftpRichPreviewLimitBytes = 256 * 1024;
  @override
  int sftpTextEditLimitBytes = 512 * 1024;
  @override
  String lanDeviceId = 'device-a';
  @override
  String lanDeviceAlias = 'My Phone';
  @override
  String relayEndpoint = 'https://relay.example.test';
  @override
  String relayHost = 'relay.example.test';
  @override
  int relayPort = 443;
  int themeToggleCount = 0;
  final List<String> terminalThemeIds = <String>[];
  final List<String> terminalFontFamilies = <String>[];
  final List<int> sftpDownloadLimits = <int>[];
  final List<int> sftpTextPreviewLimits = <int>[];
  final List<int> sftpRichPreviewLimits = <int>[];
  final List<int> sftpTextEditLimits = <int>[];
  final List<String> lanAliases = <String>[];
  final List<String> relayEndpoints = <String>[];
  final List<({String host, int port})> relayServers =
      <({String host, int port})>[];

  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  bool get isEnglish => language == AppLanguage.en;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void emitChange() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void toggleTheme() {
    themeToggleCount++;
  }

  @override
  Future<void> setTerminalThemeId(String id) async {
    terminalThemeIds.add(id);
  }

  @override
  Future<void> setTerminalFontFamily(String family) async {
    terminalFontFamilies.add(family);
  }

  @override
  Future<void> setSftpDownloadLimitBytes(int bytes) async {
    sftpDownloadLimits.add(bytes);
  }

  @override
  Future<void> setSftpTextPreviewLimitBytes(int bytes) async {
    sftpTextPreviewLimits.add(bytes);
  }

  @override
  Future<void> setSftpRichPreviewLimitBytes(int bytes) async {
    sftpRichPreviewLimits.add(bytes);
  }

  @override
  Future<void> setSftpTextEditLimitBytes(int bytes) async {
    sftpTextEditLimits.add(bytes);
  }

  @override
  Future<void> ensureLanIdentity() async {}

  @override
  Future<void> setLanDeviceAlias(String alias) async {
    lanAliases.add(alias);
  }

  @override
  Future<void> setRelayEndpoint(String endpoint) async {
    relayEndpoints.add(endpoint);
  }

  @override
  Future<void> setRelayServer({required String host, required int port}) async {
    relayServers.add((host: host, port: port));
  }
}

final class FakeConnectionViewModel extends Fake
    implements feature_connection.ConnectionViewModel {
  FakeConnectionViewModel({
    this.isLoading = false,
    List<ConnectionConfig>? connections,
  }) : connections = connections ?? <ConnectionConfig>[];

  @override
  bool isLoading;
  @override
  List<ConnectionConfig> connections;
  final List<({int oldIndex, int newIndex})> reorderCalls =
      <({int oldIndex, int newIndex})>[];
  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void emitChange() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    reorderCalls.add((oldIndex: oldIndex, newIndex: newIndex));
  }
}

final class LogCall {
  LogCall({
    required this.level,
    required this.message,
    this.error,
    this.stackTrace,
    this.details,
  });

  final String level;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;
  final String? details;
}

final class FakeAppLogService extends Fake implements AppLogService {
  final List<LogCall> calls = <LogCall>[];

  @override
  void info(String message, {String? details}) {
    calls.add(LogCall(level: 'info', message: message, details: details));
  }

  @override
  void warning(String message, {String? details}) {
    calls.add(LogCall(level: 'warning', message: message, details: details));
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    calls.add(
      LogCall(
        level: 'error',
        message: message,
        error: error,
        stackTrace: stackTrace,
        details: details,
      ),
    );
  }
}

final class FakeShortcutCommandService extends Fake
    implements ShortcutCommandService {
  @override
  int orderVersion = 0;
  @override
  List<ShortcutCommand> customCommands = <ShortcutCommand>[];
  @override
  List<String> quickCommandIds = <String>['tab'];
  final List<String> recordedUses = <String>[];
  final List<List<String>> reorderRequests = <List<String>>[];
  final List<Iterable<String>> quickSets = <Iterable<String>>[];
  int resetQuickCount = 0;
  final List<({String label, String code})> addedCommands =
      <({String label, String code})>[];
  final List<String> removedCommandIds = <String>[];
  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void emitChange() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  List<ShortcutCommand> sortByUsage(List<ShortcutCommand> commands) {
    return commands.reversed.toList(growable: false);
  }

  @override
  Future<void> recordUse(String id) async {
    recordedUses.add(id);
  }

  @override
  Future<void> reorderCommands(List<String> ids) async {
    reorderRequests.add(List<String>.of(ids));
  }

  @override
  Future<void> setQuickCommandIds(Iterable<String> ids) async {
    quickSets.add(List<String>.of(ids));
  }

  @override
  Future<void> resetQuickCommandIds() async {
    resetQuickCount++;
  }

  @override
  Future<void> addCustomCommand(String label, String code) async {
    addedCommands.add((label: label, code: code));
  }

  @override
  Future<void> removeCustomCommand(String id) async {
    removedCommandIds.add(id);
  }
}

final class FakeConnectionRepository extends Fake
    implements ConnectionRepository {
  ConnectionConfig? config;
  @override
  List<ConnectionConfig> connections = <ConnectionConfig>[];

  @override
  ConnectionConfig? getConnection(String id) =>
      id == config?.id ? config : null;
}
