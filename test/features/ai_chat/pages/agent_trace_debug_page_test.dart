import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart' as db;
import 'package:ssh_mobile/features/ai_chat/models/agent_trace_event.dart';
import 'package:ssh_mobile/features/ai_chat/pages/agent_trace_debug_page.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppLogService.instance.clear();
  });

  testWidgets('shows overview, timeline, filters, and raw content',
      (tester) async {
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

    await tester.pumpWidget(
      ChangeNotifierProvider<StorageService>.value(
        value: storage,
        child: const MaterialApp(
          home: AgentTraceDebugPage(chatId: 'chat-1', runId: 'run-1'),
        ),
      ),
    );
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

  testWidgets('shows empty trace state', (tester) async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    await tester.pumpWidget(
      ChangeNotifierProvider<StorageService>.value(
        value: storage,
        child: const MaterialApp(
          home: AgentTraceDebugPage(chatId: 'chat-1', runId: 'missing-run'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No trace events found.'), findsOneWidget);
    expect(find.text('missing-run'), findsOneWidget);
  });
}
