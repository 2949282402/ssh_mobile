import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/features/ai_chat/models/agent_trace_event.dart';
import 'package:ssh_mobile/features/ai_chat/services/llm_chat_service.dart';
import 'package:ssh_mobile/features/ai_chat/views/widgets/message_bubble.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('embedded run summary avoids storage and keeps the real outcome', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = _TestAppSettings(AppLanguage.zh);
    final storage = _CountingStorageService(
      metrics: const [],
      events: const [],
    );
    addTearDown(storage.dispose);
    addTearDown(settings.dispose);
    final semantics = tester.ensureSemantics();
    final message = _message(
      traces: [
        _messageTrace(kind: 'approval_rejected', title: 'Approval rejected'),
        _messageTrace(
          kind: 'agent_run_summary',
          content:
              '{"finalOutcome":"approvalRejected","toolCalls":12,"approvalCount":9,"approvedCount":7,"startedAt":"2026-07-13T00:00:00.000Z","finishedAt":"2026-07-13T00:00:01.234Z"}',
        ),
      ],
    );

    await tester.pumpWidget(
      _summaryHost(
        storage: storage,
        settings: settings,
        message: message,
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(storage.metricsLoads, 0);
    expect(storage.traceLoads, 0);
    expect(find.text('运行需处理'), findsOneWidget);
    expect(find.text('用户拒绝审批'), findsOneWidget);
    expect(find.text('12 个工具'), findsOneWidget);
    expect(find.text('7/9 次审批'), findsOneWidget);
    expect(find.text('1 次阻断'), findsOneWidget);
    expect(find.text('1.2s'), findsOneWidget);
    final outcome = find.byKey(const ValueKey('run-summary-outcome'));
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSemantics(outcome), matchesSemantics(label: '用户拒绝审批'));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('run summary uses metrics without loading full trace events', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = _TestAppSettings(AppLanguage.zh);
    final storage = _CountingStorageService(
      metrics: [_metric(success: false)],
      events: [
        _event(kind: 'agent_run_summary', content: '{"finalOutcome":"raw"}'),
      ],
    );
    addTearDown(storage.dispose);
    addTearDown(settings.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _summaryHost(
        storage: storage,
        settings: settings,
        message: _message(),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(storage.metricsLoads, 1);
    expect(storage.traceLoads, 0);
    expect(find.text('运行需处理'), findsOneWidget);
    expect(find.text('12 个工具'), findsOneWidget);
    expect(find.text('7/9 次审批'), findsOneWidget);
    expect(find.text('1.2s'), findsOneWidget);
    expect(find.text('运行结果未知'), findsOneWidget);
    expect(find.byKey(const ValueKey('run-summary-outcome')), findsOneWidget);
    final tools = find.byKey(const ValueKey('run-summary-tools'));
    expect(tester.getSemantics(tools), matchesSemantics(label: '12 个工具'));
    final toolsText = tester.widget<Text>(
      find.descendant(of: tools, matching: find.text('12 个工具')),
    );
    expect(toolsText.maxLines, 2);
    expect(toolsText.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);

    settings.setLanguage(AppLanguage.en);
    await tester.pump();
    expect(find.text('Run needs attention'), findsOneWidget);
    expect(find.text('12 tools'), findsOneWidget);
    expect(find.text('Run ended with an unknown result'), findsOneWidget);
    expect(storage.traceLoads, 0);
    semantics.dispose();
  });

  testWidgets('trace fallback localizes outcomes and contains long chips', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const rawOutcome = 'vendor_internal_failure_code_that_must_not_leak';
    final settings = _TestAppSettings(AppLanguage.en);
    final storage = _CountingStorageService(
      metrics: const [],
      events: [
        _event(kind: 'tool_request', status: 'requested'),
        _event(kind: 'approval_rejected', status: 'rejected'),
        _event(
          kind: 'agent_run_summary',
          status: rawOutcome,
          content: '{"finalOutcome":"$rawOutcome"}',
        ),
        _event(kind: 'agent_run_summary', content: '{malformed'),
      ],
    );
    addTearDown(storage.dispose);
    addTearDown(settings.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _summaryHost(
        storage: storage,
        settings: settings,
        message: _message(),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(storage.metricsLoads, 1);
    expect(storage.traceLoads, 1);
    expect(find.text('Run needs attention'), findsOneWidget);
    expect(find.text('1 tool'), findsOneWidget);
    expect(find.text('0/1 approvals'), findsOneWidget);
    expect(find.text('1 blocked'), findsOneWidget);
    expect(find.text('Run ended with an unknown result'), findsOneWidget);
    expect(find.textContaining(rawOutcome), findsNothing);
    final outcome = find.byKey(const ValueKey('run-summary-outcome'));
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(-1500, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(outcome),
      matchesSemantics(label: 'Run ended with an unknown result'),
    );
    final summary = find.byKey(const ValueKey('agent-run-summary-run-1'));
    expect(tester.getSize(summary).width, lessThanOrEqualTo(280));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('missing final outcome is never presented as success', (
    tester,
  ) async {
    final settings = _TestAppSettings(AppLanguage.en);
    final storage = _CountingStorageService(
      metrics: [_metric(success: true)],
      events: const [],
    );
    addTearDown(storage.dispose);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _summaryHost(
        storage: storage,
        settings: settings,
        message: _message(
          traces: [
            _messageTrace(
              kind: 'agent_run_summary',
              content: '{"toolCalls":2}',
            ),
          ],
        ),
        textScale: 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Run completed'), findsNothing);
    expect(find.text('Run needs attention'), findsOneWidget);
    expect(find.text('Run ended with an unknown result'), findsOneWidget);
    expect(storage.metricsLoads, 0);
    expect(storage.traceLoads, 0);
    expect(tester.takeException(), isNull);
  });

  test('all agent final outcomes have Chinese and English UI labels', () {
    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      for (final outcome in AgentFinalOutcome.values) {
        expect(
          strings.agentTraceOutcomeLabel(outcome.name),
          isNot(strings.agentTraceOutcomeUnknown),
          reason: '${language.name}/${outcome.name}',
        );
      }
    }
  });
}

AgentRunMetrics _metric({required bool success}) {
  final now = DateTime.utc(2026, 7, 13);
  return AgentRunMetrics(
    id: 'run-1',
    startedAt: now,
    finishedAt: now.add(const Duration(milliseconds: 1234)),
    model: 'test-model',
    promptTokens: 1,
    completionTokens: 1,
    totalTokens: 2,
    elapsedMs: 1234,
    toolCalls: 12,
    approvalCount: 9,
    approvedCount: 7,
    success: success,
  );
}

AgentTraceEvent _event({
  required String kind,
  String content = '{}',
  String status = 'info',
}) {
  return AgentTraceEvent(
    runId: 'run-1',
    chatId: 'chat-1',
    createdAt: DateTime.utc(2026, 7, 13),
    sequence: 0,
    kind: kind,
    title: kind,
    content: content,
    status: status,
  );
}

AiChatMessageRecord _message({List<AiMessageTrace> traces = const []}) {
  return AiChatMessageRecord(
    role: 'assistant',
    text: 'Result',
    traces: traces,
    createdAt: DateTime.utc(2026, 7, 13),
    agentRunId: 'run-1',
  );
}

AiMessageTrace _messageTrace({
  required String kind,
  String? title,
  String content = '{}',
}) {
  return AiMessageTrace.create(
    kind: kind,
    title: title ?? kind,
    content: content,
    createdAt: DateTime.utc(2026, 7, 13),
  );
}

Widget _summaryHost({
  required StorageService storage,
  required AppSettings settings,
  required AiChatMessageRecord message,
  required double textScale,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<StorageService>.value(value: storage),
      ChangeNotifierProvider<AppSettings>.value(value: settings),
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 280,
            child: AgentRunInlineSummary(message: message),
          ),
        ),
      ),
    ),
  );
}

class _CountingStorageService extends StorageService {
  final List<AgentRunMetrics> metrics;
  final List<AgentTraceEvent> events;
  int metricsLoads = 0;
  int traceLoads = 0;

  _CountingStorageService({required this.metrics, required this.events});

  @override
  Future<List<AgentRunMetrics>> loadAgentRunMetrics() async {
    metricsLoads += 1;
    return metrics;
  }

  @override
  Future<List<AgentTraceEvent>> loadAgentTraceEvents(String runId) async {
    traceLoads += 1;
    return events;
  }
}

class _TestAppSettings extends AppSettings {
  AppLanguage _testLanguage;

  _TestAppSettings(this._testLanguage);

  @override
  AppLanguage get language => _testLanguage;

  void setLanguage(AppLanguage language) {
    _testLanguage = language;
    notifyListeners();
  }
}
