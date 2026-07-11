import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart' as db;
import 'package:ssh_mobile/features/ai_chat/models/agent_trace_event.dart';
import 'package:ssh_mobile/features/ai_chat/pages/agent_trace_debug_page.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppLogService.instance.clear();
  });

  testWidgets('shows overview, timeline, filters, and raw content', (
    tester,
  ) async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    final now = DateTime.utc(2026, 6, 22, 10);
    await storage.saveAgentRunMetrics(
      AgentRunMetrics(
        id: 'run-1',
        startedAt: now,
        finishedAt: now.add(const Duration(seconds: 2)),
        model: 'main-model',
        helperModel: 'helper-model',
        auditModel: 'audit-model',
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 15,
        elapsedMs: 2000,
        toolCalls: 1,
        approvalCount: 1,
      ),
    );
    await storage.saveAgentTraceEvents([
      AgentTraceEvent(
        id: 'event-1',
        runId: 'run-1',
        chatId: 'chat-1',
        createdAt: now,
        sequence: 0,
        kind: 'agent_run_started',
        title: 'Agent run started',
        content: '{"model":"main-model"}',
      ),
      AgentTraceEvent(
        id: 'event-2',
        runId: 'run-1',
        chatId: 'chat-1',
        createdAt: now.add(const Duration(milliseconds: 100)),
        sequence: 1,
        kind: 'tool_result',
        title: 'Tool result: run_command',
        content: '{"resultPreview":"uptime ok"}',
        toolName: 'run_command',
        status: 'success',
      ),
      AgentTraceEvent(
        id: 'event-3',
        runId: 'run-1',
        chatId: 'chat-1',
        createdAt: now.add(const Duration(milliseconds: 200)),
        sequence: 2,
        kind: 'agent_run_summary',
        title: 'Agent run summary',
        content:
            '{"finalOutcome":"success","selectedToolSet":["run_command"],"memorySources":["rag:ops"]}',
        status: 'completed',
      ),
    ]);

    await tester.pumpWidget(_traceTestApp(storage: storage, runId: 'run-1'));
    await tester.pumpAndSettle();

    expect(find.text('Overview'), findsOneWidget);
    expect(find.textContaining('Model: main-model'), findsOneWidget);
    expect(find.textContaining('3 events'), findsOneWidget);
    expect(find.textContaining('Selected tools: run_command'), findsOneWidget);
    expect(find.textContaining('Memory sources: rag:ops'), findsOneWidget);
    expect(find.textContaining('Tool result: run_command'), findsOneWidget);

    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tool result: run_command'), findsOneWidget);
    expect(find.textContaining('Agent run started'), findsNothing);
    expect(find.textContaining('uptime ok'), findsOneWidget);

    await tester.tap(find.textContaining('Tool result: run_command'));
    await tester.pumpAndSettle();
    expect(find.textContaining('uptime ok'), findsWidgets);
  });

  testWidgets('lazily builds a large trace on a narrow mobile viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    final now = DateTime.utc(2026, 6, 22, 10);
    await storage.saveAgentTraceEvents([
      for (var index = 0; index < agentTraceEventsPerRunLimit; index++)
        AgentTraceEvent(
          id: 'event-$index',
          runId: 'run-large',
          chatId: 'chat-1',
          createdAt: now.add(Duration(milliseconds: index)),
          sequence: index,
          kind: 'tool_result',
          title: 'Event $index',
          content: 'Result $index',
          toolName: 'run_command',
          status: 'success',
        ),
    ]);

    await tester.pumpWidget(
      _traceTestApp(storage: storage, runId: 'run-large'),
    );
    await tester.pumpAndSettle();

    final initiallyBuilt = find.byType(ExpansionTile).evaluate().length;
    expect(initiallyBuilt, lessThan(agentTraceEventsPerRunLimit));
    expect(tester.takeException(), isNull);

    final traceScroll = find
        .descendant(
          of: find.byKey(const ValueKey('agent-trace-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final allFilter = find.byKey(const ValueKey('trace-filter-all'));
    await tester.scrollUntilVisible(allFilter, 300, scrollable: traceScroll);
    expect(tester.getSize(allFilter).height, greaterThanOrEqualTo(48));

    final firstEvent = find.byKey(const ValueKey('trace-event-event-0'));
    await tester.scrollUntilVisible(firstEvent, 300, scrollable: traceScroll);
    expect(find.byType(ExpansionTile), findsAtLeastNWidgets(1));
    expect(
      find.byType(ExpansionTile).evaluate().length,
      lessThan(agentTraceEventsPerRunLimit),
    );

    final lastEvent = find.byKey(const ValueKey('trace-event-event-299'));
    await tester.scrollUntilVisible(
      lastEvent,
      800,
      scrollable: traceScroll,
      maxScrolls: 80,
    );
    await tester.pumpAndSettle();

    expect(lastEvent, findsOneWidget);
    expect(find.text('299. Event 299'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bounds long raw content and keeps trace actions accessible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (
      methodCall,
    ) async {
      if (methodCall.method == 'Clipboard.setData') {
        copiedText =
            (methodCall.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    final rawInput = List.generate(
      160,
      (index) => 'line $index ${List.filled(96, 'x').join()}',
    ).join('\n');
    final event = AgentTraceEvent(
      id: 'event-long',
      runId: 'run-long',
      chatId: 'chat-1',
      createdAt: DateTime.utc(2026, 6, 22, 10),
      sequence: 0,
      kind: 'tool_result',
      title: 'Long raw event',
      content: rawInput,
      toolName: 'run_command',
      status: 'success',
    );
    await storage.saveAgentTraceEvents([event]);

    await tester.pumpWidget(_traceTestApp(storage: storage, runId: 'run-long'));
    await tester.pumpAndSettle();

    final traceScroll = find
        .descendant(
          of: find.byKey(const ValueKey('agent-trace-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final expansion = find.byKey(
      const PageStorageKey<String>('trace-expansion-event-long'),
    );
    await tester.scrollUntilVisible(expansion, 300, scrollable: traceScroll);
    expect(tester.getSize(expansion).height, greaterThanOrEqualTo(48));
    await tester.tap(find.text('0. Long raw event'));
    await tester.pumpAndSettle();

    final raw = find.byKey(const ValueKey('trace-raw-event-long'));
    expect(raw, findsOneWidget);
    expect(tester.getSize(raw).height, lessThanOrEqualTo(280));
    await tester.scrollUntilVisible(raw, 300, scrollable: traceScroll);
    await tester.pumpAndSettle();

    final verticalRawScroll = find.descendant(
      of: raw,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.vertical,
      ),
    );
    final horizontalRawScroll = find.descendant(
      of: raw,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
    );
    expect(verticalRawScroll, findsOneWidget);
    expect(horizontalRawScroll, findsOneWidget);
    await tester.drag(verticalRawScroll, const Offset(0, -120));
    await tester.dragFrom(
      tester.getTopLeft(raw) + const Offset(120, 40),
      const Offset(-120, 0),
    );
    await tester.pump();

    final copy = find.byKey(const ValueKey('trace-copy-event-long'));
    expect(tester.getSize(copy).height, greaterThanOrEqualTo(48));
    await tester.tap(copy);
    await tester.pump();
    expect(copiedText, event.content);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows empty trace state', (tester) async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    await tester.pumpWidget(
      _traceTestApp(storage: storage, runId: 'missing-run'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('No persisted trace events found for this run.'),
      findsOneWidget,
    );
    expect(find.text('missing-run'), findsOneWidget);
  });

  testWidgets(
    'shows metrics overview when events are empty but metrics exist',
    (tester) async {
      final database = db.AppDatabase.forTesting();
      addTearDown(database.close);
      final storage = StorageService(database: database);
      addTearDown(storage.dispose);
      await storage.init();

      final now = DateTime.utc(2026, 6, 22, 10);
      await storage.saveAgentRunMetrics(
        AgentRunMetrics(
          id: 'run-metrics-only',
          startedAt: now,
          finishedAt: now.add(const Duration(seconds: 2)),
          model: 'main-model',
          helperModel: 'helper-model',
          auditModel: 'audit-model',
          promptTokens: 10,
          completionTokens: 5,
          totalTokens: 15,
          elapsedMs: 2000,
          toolCalls: 1,
          approvalCount: 1,
        ),
      );

      await tester.pumpWidget(
        _traceTestApp(storage: storage, runId: 'run-metrics-only'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Overview'), findsOneWidget);
      expect(find.textContaining('Model: main-model'), findsOneWidget);
      expect(
        find.text('No persisted trace events found for this run.'),
        findsOneWidget,
      );
      expect(find.text('run-metrics-only'), findsOneWidget);
    },
  );

  testWidgets('updates trace chrome when the app language changes', (
    tester,
  ) async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    await storage.saveAgentTraceEvents([
      AgentTraceEvent(
        id: 'event-language',
        runId: 'run-language',
        chatId: 'chat-1',
        createdAt: DateTime.utc(2026, 6, 22, 10),
        sequence: 0,
        kind: 'agent_run_summary',
        title: 'Agent run summary',
        content:
            '{"finalOutcome":"modelError","selectedToolSet":["run_command"],"memorySources":["rag:ops"]}',
        toolName: 'run_command',
        status: 'failed',
      ),
    ]);
    final settings = _TestAppSettings(AppLanguage.en);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _traceTestApp(
        storage: storage,
        runId: 'run-language',
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Agent Trace'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);

    settings.setLanguageForTest(AppLanguage.zh);
    await tester.pumpAndSettle();

    expect(find.text('Agent 执行轨迹'), findsOneWidget);
    expect(find.text('执行概览'), findsOneWidget);
    expect(find.text('1 个事件'), findsOneWidget);
    expect(find.text('状态: 模型请求失败'), findsOneWidget);
    expect(find.text('已选工具: run_command'), findsOneWidget);
    expect(find.text('记忆来源: rag:ops'), findsOneWidget);
    expect(find.text('最终原因: 模型请求失败'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('审批'), findsOneWidget);
    expect(find.text('已拦截'), findsOneWidget);
    expect(find.text('错误'), findsOneWidget);

    final traceScroll = find
        .descendant(
          of: find.byKey(const ValueKey('agent-trace-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final eventTitle = find.text('0. Agent run summary');
    await tester.scrollUntilVisible(eventTitle, 300, scrollable: traceScroll);
    await tester.tap(eventTitle);
    await tester.pumpAndSettle();
    expect(find.text('复制原始内容'), findsOneWidget);
    expect(find.textContaining('agent_run_summary'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _traceTestApp({
  required StorageService storage,
  required String runId,
  AppLanguage language = AppLanguage.en,
  _TestAppSettings? settings,
}) {
  final app = MaterialApp(
    home: AgentTraceDebugPage(chatId: 'chat-1', runId: runId),
  );
  final withSettings = settings == null
      ? ChangeNotifierProvider<AppSettings>(
          create: (_) => _TestAppSettings(language),
          child: app,
        )
      : ChangeNotifierProvider<AppSettings>.value(value: settings, child: app);
  return ChangeNotifierProvider<StorageService>.value(
    value: storage,
    child: withSettings,
  );
}

class _TestAppSettings extends AppSettings {
  _TestAppSettings(this._testLanguage);

  AppLanguage _testLanguage;

  @override
  AppLanguage get language => _testLanguage;

  void setLanguageForTest(AppLanguage value) {
    if (value == _testLanguage) return;
    _testLanguage = value;
    notifyListeners();
  }
}
