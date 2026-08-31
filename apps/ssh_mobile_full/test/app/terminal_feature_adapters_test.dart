// Terminal Feature 的 App Shell 适配器测试。

import 'package:connection_core/connection_core.dart';
import 'package:feature_terminal/feature_terminal.dart' as feature_terminal;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/terminal_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/shortcut_command_service.dart';

import 'support/feature_adapter_test_fakes.dart';

void main() {
  test('terminal settings adapter maps settings and forwards writes', () async {
    final settings = FakeAppSettings()..language = AppLanguage.zh;
    final adapter = AppTerminalSettingsAdapter(settings);
    var notifications = 0;
    adapter.addListener(() => notifications++);

    expect(adapter.language, AppLanguage.zh);
    expect(adapter.isDarkMode, isFalse);
    expect(adapter.oledDark, isFalse);
    expect(adapter.terminalThemeId, 'default');
    expect(adapter.terminalFontFamily, 'monospace');

    adapter.toggleTheme();
    expect(settings.themeToggleCount, 1);
    await adapter.setTerminalThemeId('solarized');
    await adapter.setTerminalFontFamily('Fira Code');
    expect(settings.terminalThemeIds, <String>['solarized']);
    expect(settings.terminalFontFamilies, <String>['Fira Code']);

    settings.emitChange();
    expect(notifications, 1);

    adapter.dispose();
    adapter.dispose();
    settings.emitChange();
    expect(notifications, 1);
  });

  test(
    'terminal shortcut adapter maps and forwards shortcut commands',
    () async {
      final service = FakeShortcutCommandService();
      service.customCommands = <ShortcutCommand>[
        const ShortcutCommand(
          id: 'c1',
          label: 'List',
          code: 'ls',
          custom: true,
        ),
      ];
      final adapter = AppTerminalShortcutAdapter(service);
      var notifications = 0;
      adapter.addListener(() => notifications++);

      expect(adapter.orderVersion, 0);
      expect(adapter.customCommands.single.id, 'c1');
      expect(adapter.customCommands.single.custom, isTrue);
      expect(adapter.quickCommandIds, <String>['tab']);

      final sorted = adapter
          .sortByUsage(<feature_terminal.TerminalShortcutCommand>[
            const feature_terminal.TerminalShortcutCommand(
              id: 'a',
              label: 'A',
              code: 'echo a',
            ),
            const feature_terminal.TerminalShortcutCommand(
              id: 'b',
              label: 'B',
              code: 'echo b',
            ),
          ]);
      expect(sorted.first.id, 'b');

      await adapter.recordUse('a');
      await adapter.reorderCommands(<String>['a']);
      await adapter.setQuickCommandIds(<String>['tab']);
      await adapter.resetQuickCommandIds();
      await adapter.addCustomCommand('List', 'ls');
      await adapter.removeCustomCommand('c1');

      expect(service.recordedUses, <String>['a']);
      expect(service.reorderRequests, <List<String>>[
        <String>['a'],
      ]);
      expect(service.quickSets, hasLength(1));
      expect(service.resetQuickCount, 1);
      expect(service.addedCommands.single.label, 'List');
      expect(service.removedCommandIds, <String>['c1']);

      service.emitChange();
      expect(notifications, 1);
      adapter.dispose();
      adapter.dispose();
      service.emitChange();
      expect(notifications, 1);
    },
  );

  test('terminal connection adapter resolves a connection snapshot', () {
    final repository = FakeConnectionRepository()
      ..config = ConnectionConfig(
        id: 'c1',
        name: 'Server A',
        host: '10.0.0.1',
        port: 22,
        username: 'root',
      );
    final adapter = AppTerminalConnectionAdapter(
      navigatorKey: GlobalKey<NavigatorState>(),
      connectionRepository: repository,
      sshService: TestSshService(connection: repository.config),
    );

    final info = adapter.getConnection('c1')!;
    expect(info.id, 'c1');
    expect(info.name, 'Server A');
    expect(info.host, '10.0.0.1');
    expect(info.port, 22);
    expect(info.username, 'root');

    expect(adapter.getConnection('missing'), isNull);
    expect(adapter.defaultDisplayNameForConnection('c1'), 'Server A');
  });

  test(
    'terminal connection opens a session without a mounted navigator',
    () async {
      final service = FakeSshService()..openSessionResult = 'session-1';
      final adapter = AppTerminalConnectionAdapter(
        navigatorKey: GlobalKey<NavigatorState>(),
        connectionRepository: FakeConnectionRepository(),
        sshService: service,
      );

      final sessionId = await adapter.openSession('c1', displayName: 'win');

      expect(sessionId, 'session-1');
      expect(service.capturedUnknownHostKey, isNull);
    },
  );

  testWidgets('terminal connection confirms host keys with the navigator', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final service = FakeSshService()..invokeUnknownHostKey = true;
    service.unknownHostKeyRequest = ssh_core.SshHostKeyPromptRequest(
      connectionId: 'c1',
      connectionName: 'Server A',
      host: '10.0.0.1',
      port: 22,
      username: 'root',
      algorithm: 'ssh-ed25519',
      fingerprint: 'SHA256:abc',
    );
    final settings = FakeAppSettings()..language = AppLanguage.en;
    final adapter = AppTerminalConnectionAdapter(
      navigatorKey: navigatorKey,
      connectionRepository: FakeConnectionRepository(),
      sshService: service,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppSettings>.value(
        value: settings,
        child: MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
      ),
    );

    final future = adapter.openSession('c1');
    await tester.pumpAndSettle();
    expect(find.text('Trust SSH host key?'), findsOneWidget);
    await tester.tap(find.text('Trust key'));
    await tester.pumpAndSettle();
    expect(await future, 'session-1');
  });

  testWidgets('terminal connection opens the connection editor routes', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final pushedNames = <String>[];
    final pushedArguments = <Object?>[];
    final adapter = AppTerminalConnectionAdapter(
      navigatorKey: navigatorKey,
      connectionRepository: FakeConnectionRepository(),
      sshService: FakeSshService(),
    );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const SizedBox(),
        onGenerateRoute: (settings) {
          pushedNames.add(settings.name ?? '');
          pushedArguments.add(settings.arguments);
          return MaterialPageRoute<void>(builder: (_) => const SizedBox());
        },
      ),
    );

    final firstPush = adapter.openConnectionEditor('c1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(pushedNames, <String>['/edit']);

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await firstPush;

    final secondPush = adapter.openConnectionEditor('c2', isNew: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(pushedNames, <String>['/edit', '/add']);
    expect(pushedArguments, <Object?>['c1', null]);
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await secondPush;
  });

  test('terminal connection editor is a no-op without a navigator', () async {
    final adapter = AppTerminalConnectionAdapter(
      navigatorKey: GlobalKey<NavigatorState>(),
      connectionRepository: FakeConnectionRepository(),
      sshService: FakeSshService(),
    );

    await expectLater(adapter.openConnectionEditor('c1'), completes);
    await expectLater(
      adapter.openConnectionEditor('c1', isNew: true),
      completes,
    );
  });

  test('terminal logger adapter forwards info, warning, and error', () {
    final logger = FakeAppLogService();
    final adapter = AppTerminalLoggerAdapter(logger);
    final failure = StateError('boom');
    final stackTrace = StackTrace.current;

    adapter.info('info');
    adapter.warning('warn');
    adapter.warning('warn-with-error', error: failure, stackTrace: stackTrace);
    adapter.error('err', error: failure, stackTrace: stackTrace);

    expect(logger.calls, hasLength(4));
    expect(logger.calls[0].level, 'info');
    expect(logger.calls[1].level, 'warning');
    expect(logger.calls[1].details, isNull);
    expect(logger.calls[2].details, '$failure\n$stackTrace');
    expect(logger.calls[3].level, 'error');
    expect(logger.calls[3].error, same(failure));
    expect(logger.calls[3].stackTrace, same(stackTrace));
  });

  test(
    'terminal history repository forwards every repository method',
    () async {
      final primary = FakeTerminalHistoryRepository();
      final adapter = AppTerminalHistoryRepository(primary);
      final record = feature_terminal.TerminalHistoryRecord(
        sessionId: 's1',
        connectionId: 'c1',
        connectionName: 'Server A',
        displayName: 'win',
        tmuxSessionName: null,
        state: 'connected',
        errorMessage: null,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
      );
      primary.records = <feature_terminal.TerminalHistoryRecord>[record];

      expect(
        await adapter.loadRecords(),
        <feature_terminal.TerminalHistoryRecord>[record],
      );
      await adapter.saveRecord(record);
      await adapter.removeRecord('s1');
      await adapter.replaceAll(<feature_terminal.TerminalHistoryRecord>[
        record,
      ]);

      expect(primary.saved.single, same(record));
      expect(primary.removed.single, 's1');
      expect(primary.replaced.single.single, same(record));
    },
  );
}
