import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/features/terminal/viewmodels/terminal_history_viewmodel.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_history_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads records and preserves refresh delete and copy actions', (
    tester,
  ) async {
    final loadGate = Completer<List<TerminalHistoryRecord>>();
    final records = <TerminalHistoryRecord>[
      _record(
        sessionId: 'session-connected',
        displayName: 'Production shell',
        connectionName: 'gateway.example.com',
        state: 'connected',
        tmuxSessionName: 'ops',
      ),
      _record(
        sessionId: 'session-error',
        displayName: 'Failed maintenance shell',
        connectionName: 'database.example.com',
        state: 'error',
        errorMessage: 'Connection timed out',
      ),
    ];
    var loadCalls = 0;
    final deleted = <String>[];
    final copied = <String>[];
    final viewModel = TerminalHistoryViewModel.forTesting(
      loadRecords: () {
        loadCalls += 1;
        if (loadCalls == 1) return loadGate.future;
        return Future.value(List.unmodifiable(records));
      },
      removeRecord: (sessionId) async {
        deleted.add(sessionId);
        records.removeWhere((record) => record.sessionId == sessionId);
      },
      copyCommand: (command) async => copied.add(command),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _historyHost(viewModel: viewModel, language: AppLanguage.en),
    );
    await tester.pump();

    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('terminal-history-loading')))
          .label,
      'Loading connection history…',
    );
    expect(loadCalls, 1);

    loadGate.complete(List.unmodifiable(records));
    await tester.pumpAndSettle();

    expect(find.text('2 recent sessions'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Connection error'), findsOneWidget);
    expect(find.text('Connection timed out'), findsOneWidget);
    expect(find.text("tmux kill-session -t 'ops'"), findsOneWidget);
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('terminal-history-overview-title')),
          )
          .flagsCollection
          .isHeader,
      isTrue,
    );

    for (final key in const [
      ValueKey('terminal-history-back'),
      ValueKey('terminal-history-refresh'),
      ValueKey('terminal-history-delete-session-connected'),
      ValueKey('terminal-history-copy-session-connected'),
    ]) {
      final finder = find.byKey(key);
      await tester.ensureVisible(finder);
      await tester.pump();
      expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
    }

    final copyAction = find.byKey(
      const ValueKey('terminal-history-copy-session-connected'),
    );
    await tester.ensureVisible(copyAction);
    await tester.tap(copyAction);
    await tester.pump();
    expect(copied, ["tmux kill-session -t 'ops'"]);
    expect(find.text('Server cleanup command copied'), findsOneWidget);

    final deleteAction = find.byKey(
      const ValueKey('terminal-history-delete-session-connected'),
    );
    await tester.ensureVisible(deleteAction);
    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    expect(deleted, ['session-connected']);
    expect(loadCalls, 2);
    expect(
      find.byKey(const ValueKey('terminal-history-record-session-connected')),
      findsNothing,
    );
    expect(find.text('1 recent session'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('terminal-history-refresh')));
    await tester.pumpAndSettle();
    expect(loadCalls, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state explains the page and can refresh', (tester) async {
    var loadCalls = 0;
    final viewModel = TerminalHistoryViewModel.forTesting(
      loadRecords: () async {
        loadCalls += 1;
        return const [];
      },
      removeRecord: (_) async {},
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _historyHost(viewModel: viewModel, language: AppLanguage.zh),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无连接历史'), findsOneWidget);
    expect(find.text('最近打开的终端会话及其连接状态会显示在这里。'), findsOneWidget);
    final refreshAction = find.byKey(
      const ValueKey('terminal-history-empty-refresh'),
    );
    expect(tester.getSize(refreshAction).height, greaterThanOrEqualTo(48));

    await tester.tap(refreshAction);
    await tester.pumpAndSettle();
    expect(loadCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('load failure hides raw details and retry recovers', (
    tester,
  ) async {
    final loadGate = Completer<List<TerminalHistoryRecord>>();
    var loadCalls = 0;
    final viewModel = TerminalHistoryViewModel.forTesting(
      loadRecords: () {
        loadCalls += 1;
        if (loadCalls == 1) return loadGate.future;
        return Future.value(const []);
      },
      removeRecord: (_) async {},
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _historyHost(viewModel: viewModel, language: AppLanguage.en),
    );
    await tester.pump();
    loadGate.completeError(StateError('password=do-not-render'));
    await tester.pumpAndSettle();

    expect(find.text('Could not load connection history'), findsOneWidget);
    expect(find.textContaining('password='), findsNothing);
    final retryAction = find.byKey(const ValueKey('terminal-history-retry'));
    expect(tester.getSize(retryAction).height, greaterThanOrEqualTo(48));

    await tester.tap(retryAction);
    await tester.pumpAndSettle();
    expect(loadCalls, 2);
    expect(find.text('No connection history yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete and copy failures show safe feedback', (tester) async {
    final viewModel = TerminalHistoryViewModel.forTesting(
      loadRecords: () async => [
        _record(
          sessionId: 'session-actions-fail',
          displayName: 'Operations shell',
          connectionName: 'operations.example.com',
          state: 'disconnected',
          tmuxSessionName: 'operations',
        ),
      ],
      removeRecord: (_) async {
        throw StateError('password=delete-secret');
      },
      copyCommand: (_) async {
        throw StateError('token=copy-secret');
      },
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _historyHost(viewModel: viewModel, language: AppLanguage.en),
    );
    await tester.pumpAndSettle();

    final deleteAction = find.byKey(
      const ValueKey('terminal-history-delete-session-actions-fail'),
    );
    await tester.ensureVisible(deleteAction);
    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    expect(
      find.text('Could not delete this history record. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('delete-secret'), findsNothing);
    expect(tester.takeException(), isNull);

    final copyAction = find.byKey(
      const ValueKey('terminal-history-copy-session-actions-fail'),
    );
    await tester.ensureVisible(copyAction);
    await tester.tap(copyAction);
    await tester.pumpAndSettle();
    expect(
      find.text('Could not copy the cleanup command. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('copy-secret'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete action is disabled while its operation is pending', (
    tester,
  ) async {
    final removeGate = Completer<void>();
    final removeStarted = Completer<void>();
    final records = <TerminalHistoryRecord>[
      _record(
        sessionId: 'session-pending-delete',
        displayName: 'Pending delete shell',
        connectionName: 'pending.example.com',
        state: 'disconnected',
      ),
    ];
    final viewModel = TerminalHistoryViewModel.forTesting(
      loadRecords: () async => List.unmodifiable(records),
      removeRecord: (_) async {
        removeStarted.complete();
        await removeGate.future;
        records.clear();
      },
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _historyHost(viewModel: viewModel, language: AppLanguage.zh),
    );
    await tester.pumpAndSettle();

    final deleteAction = find.byKey(
      const ValueKey('terminal-history-delete-session-pending-delete'),
    );
    await tester.ensureVisible(deleteAction);
    await tester.tap(deleteAction);
    await removeStarted.future;
    await tester.pump();

    expect(tester.widget<IconButton>(deleteAction).onPressed, isNull);
    expect(
      find.byKey(
        const ValueKey(
          'terminal-history-delete-progress-session-pending-delete',
        ),
      ),
      findsOneWidget,
    );

    removeGate.complete();
    await tester.pumpAndSettle();
    expect(find.text('暂无连接历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stored connection errors are redacted and bounded', (
    tester,
  ) async {
    final longError =
        'Connection failed: password=super-secret ${List.filled(600, 'x').join()}';
    final viewModel = TerminalHistoryViewModel.forTesting(
      loadRecords: () async => [
        _record(
          sessionId: 'session-secret-error',
          displayName: 'Redacted error shell',
          connectionName: 'redacted.example.com',
          state: 'error',
          errorMessage: longError,
        ),
      ],
      removeRecord: (_) async {},
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _historyHost(viewModel: viewModel, language: AppLanguage.en),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('super-secret'), findsNothing);
    expect(find.textContaining('[REDACTED]'), findsOneWidget);
    expect(find.textContaining('[truncated]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long content remains usable at 320dp and 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    final viewModel = TerminalHistoryViewModel.forTesting(
      loadRecords: () async => [
        _record(
          sessionId: 'session-long',
          displayName:
              'A very long production maintenance terminal window name that must remain stable',
          connectionName:
              'a-very-long-host-name-without-natural-breaks.internal.example.com',
          state: 'connecting',
          tmuxSessionName: 'long-running-maintenance-session',
          errorMessage:
              'A long diagnostic message that should wrap without pushing actions outside the viewport.',
        ),
      ],
      removeRecord: (_) async {},
      copyCommand: (_) async {},
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      _historyHost(
        viewModel: viewModel,
        language: AppLanguage.en,
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 recent session'), findsOneWidget);
    final scrollable = find
        .descendant(
          of: find.byKey(const ValueKey('terminal-history-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final copyAction = find.byKey(
      const ValueKey('terminal-history-copy-session-long'),
    );
    await tester.scrollUntilVisible(copyAction, 260, scrollable: scrollable);
    await tester.ensureVisible(copyAction);
    await tester.pumpAndSettle();
    expect(find.text('Connecting'), findsOneWidget);
    expect(tester.getSize(copyAction).height, greaterThanOrEqualTo(56));
    expect(tester.getBottomRight(copyAction).dy, lessThanOrEqualTo(544));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'wide short layout respects asymmetric safe areas and max width',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 360);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(
        left: 120,
        right: 20,
        bottom: 20,
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      final viewModel = TerminalHistoryViewModel.forTesting(
        loadRecords: () async => [
          _record(
            sessionId: 'session-landscape',
            displayName: 'Landscape terminal',
            connectionName: 'landscape.example.com',
            state: 'disconnected',
          ),
        ],
        removeRecord: (_) async {},
      );
      addTearDown(viewModel.dispose);

      await tester.pumpWidget(
        _historyHost(viewModel: viewModel, language: AppLanguage.zh),
      );
      await tester.pumpAndSettle();

      final content = find.byKey(const ValueKey('terminal-history-content'));
      final rect = tester.getRect(content);
      expect(rect.width, lessThanOrEqualTo(820));
      expect(rect.left, greaterThanOrEqualTo(134));
      expect(rect.right, lessThanOrEqualTo(966));
      expect(find.text('已断开'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    },
  );
}

TerminalHistoryRecord _record({
  required String sessionId,
  required String displayName,
  required String connectionName,
  required String state,
  String? tmuxSessionName,
  String? errorMessage,
}) {
  return TerminalHistoryRecord(
    sessionId: sessionId,
    connectionId: 'connection-$sessionId',
    connectionName: connectionName,
    displayName: displayName,
    tmuxSessionName: tmuxSessionName,
    state: state,
    errorMessage: errorMessage,
    createdAt: DateTime(2026, 7, 13, 8, 30),
    updatedAt: DateTime(2026, 7, 13, 9, 45),
  );
}

Widget _historyHost({
  required TerminalHistoryViewModel viewModel,
  required AppLanguage language,
  double textScale = 1,
}) {
  return ChangeNotifierProvider<AppSettings>(
    create: (_) => _TestAppSettings(language),
    child: MaterialApp(
      theme: AppTheme.lightThemeFor(),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale));
        return MediaQuery(data: mediaQuery, child: child!);
      },
      home: TerminalHistoryScreen(viewModel: viewModel),
    ),
  );
}

class _TestAppSettings extends AppSettings {
  _TestAppSettings(this._testLanguage);

  final AppLanguage _testLanguage;

  @override
  AppLanguage get language => _testLanguage;
}
