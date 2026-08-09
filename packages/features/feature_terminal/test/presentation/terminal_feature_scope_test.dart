import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart';

import 'package:feature_terminal/feature_terminal.dart';

import '../fakes/terminal_test_fakes.dart';

void main() {
  testWidgets('TerminalFeatureScope exposes only the supplied public Ports', (
    tester,
  ) async {
    final settings = FakeTerminalSettings();
    final shortcuts = FakeTerminalShortcuts();
    final capability = FakeTerminalCapability();
    final manager = FakeSshSessionManager(capability);
    final logger = FakeTerminalLogger();
    final history = _FakeHistoryRepository();

    late SshSessionManager resolvedManager;
    late TerminalSettingsPort resolvedSettings;
    late TerminalShortcutPort resolvedShortcuts;
    late TerminalConnectionPort resolvedConnections;
    late TerminalLoggerPort resolvedLogger;
    late TerminalHistoryRepository resolvedHistory;

    await tester.pumpWidget(
      TerminalFeatureScope(
        sshSessionManager: manager,
        settings: settings,
        shortcuts: shortcuts,
        connections: _FakeConnections(),
        logger: logger,
        historyRepository: history,
        child: Builder(
          builder: (context) {
            resolvedManager = context.read<SshSessionManager>();
            resolvedSettings = context.read<TerminalSettingsPort>();
            resolvedShortcuts = context.read<TerminalShortcutPort>();
            resolvedConnections = context.read<TerminalConnectionPort>();
            resolvedLogger = context.read<TerminalLoggerPort>();
            resolvedHistory = context.read<TerminalHistoryRepository>();
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(resolvedManager, same(manager));
    expect(resolvedSettings, same(settings));
    expect(resolvedShortcuts, same(shortcuts));
    expect(resolvedConnections, isA<_FakeConnections>());
    expect(resolvedLogger, same(logger));
    expect(resolvedHistory, same(history));

    await capability.close();
  });
}

final class _FakeHistoryRepository implements TerminalHistoryRepository {
  @override
  Future<List<TerminalHistoryRecord>> loadRecords() async => const [];

  @override
  Future<void> removeRecord(String sessionId) async {}

  @override
  Future<void> replaceAll(Iterable<TerminalHistoryRecord> records) async {}

  @override
  Future<void> saveRecord(TerminalHistoryRecord record) async {}
}

final class _FakeConnections implements TerminalConnectionPort {
  @override
  TerminalConnectionInfo? getConnection(String connectionId) => null;

  @override
  String defaultDisplayNameForConnection(String connectionId) => connectionId;

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
  }) async => null;

  @override
  Future<void> openConnectionEditor(
    String connectionId, {
    bool isNew = false,
  }) async {}
}
