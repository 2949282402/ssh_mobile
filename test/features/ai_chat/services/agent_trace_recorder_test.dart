import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/models/agent_trace_event.dart';
import 'package:ssh_mobile/features/ai_chat/services/agent_trace_recorder.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  group('AgentTraceRecorder', () {
    test('record increments sequence and redacts content', () {
      final repository = _FakeAgentTraceRepository();
      final recorder = AgentTraceRecorder(
        repository: repository,
        runId: 'run-1',
        chatId: 'chat-1',
      );

      recorder
        ..record(const LlmTraceEvent(
          kind: 'tool_request',
          title: 'Tool request: run_command',
          content: '{"password":"secret","command":"uptime"}',
        ))
        ..record(const LlmTraceEvent(
          kind: 'approval',
          title: 'Tool action approved',
          content: 'approved',
        ));

      expect(recorder.bufferedEvents.map((event) => event.sequence), [0, 1]);
      expect(recorder.bufferedEvents.first.toolName, 'run_command');
      expect(recorder.bufferedEvents.first.content, isNot(contains('secret')));
      expect(recorder.bufferedEvents.last.status, 'approved');
    });

    test('flush saves buffered events and clears buffer', () async {
      final repository = _FakeAgentTraceRepository();
      final recorder = AgentTraceRecorder(
        repository: repository,
        runId: 'run-1',
        chatId: 'chat-1',
      );

      recorder.record(const LlmTraceEvent(
        kind: 'agent_run_summary',
        title: 'Agent run summary',
        content: '{"finalOutcome":"success"}',
      ));
      await recorder.flush();

      expect(repository.saved, hasLength(1));
      expect(recorder.bufferedEvents, isEmpty);
      await recorder.flush();
      expect(repository.saved, hasLength(1));
    });

    test('clear empties buffer and resets sequence', () {
      final recorder = AgentTraceRecorder(
        repository: _FakeAgentTraceRepository(),
        runId: 'run-1',
        chatId: 'chat-1',
      );

      recorder.record(const LlmTraceEvent(
        kind: 'info',
        title: 'one',
        content: '',
      ));
      recorder.clear();
      recorder.record(const LlmTraceEvent(
        kind: 'info',
        title: 'two',
        content: '',
      ));

      expect(recorder.bufferedEvents.single.sequence, 0);
      expect(recorder.bufferedEvents.single.title, 'two');
    });

    test('flush propagates repository failures with buffer intact', () async {
      final repository = _FakeAgentTraceRepository(throwOnSave: true);
      final recorder = AgentTraceRecorder(
        repository: repository,
        runId: 'run-1',
        chatId: 'chat-1',
      );
      recorder.record(const LlmTraceEvent(
        kind: 'info',
        title: 'one',
        content: '',
      ));

      await expectLater(recorder.flush(), throwsStateError);
      expect(recorder.bufferedEvents, hasLength(1));
    });

    test('record previews oversized json string fields before buffering', () {
      final recorder = AgentTraceRecorder(
        repository: _FakeAgentTraceRepository(),
        runId: 'run-1',
        chatId: 'chat-1',
      );

      recorder.record(LlmTraceEvent(
        kind: 'tool_result',
        title: 'Tool result: run_command',
        content:
            '{"result":"${'x' * 5000}","token":"sk-abcdefghijklmnopqrstuvwxyz"}',
      ));

      final event = recorder.bufferedEvents.single;
      expect(event.content.length, lessThan(2000));
      expect(event.content, contains('[truncated]'));
      expect(event.content, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz')));
    });

    test('agent_run_summary with approvedCount should not become approved', () {
      final recorder = AgentTraceRecorder(
        repository: _FakeAgentTraceRepository(),
        runId: 'run-1',
        chatId: 'chat-1',
      );

      recorder.record(const LlmTraceEvent(
        kind: 'agent_run_summary',
        title: 'Agent run summary',
        content: '{"finalOutcome":"success","approvedCount":1}',
      ));

      expect(recorder.bufferedEvents.single.status, 'success');
    });

    test('agent_run_summary without finalOutcome should become completed', () {
      final recorder = AgentTraceRecorder(
        repository: _FakeAgentTraceRepository(),
        runId: 'run-1',
        chatId: 'chat-1',
      );

      recorder.record(const LlmTraceEvent(
        kind: 'agent_run_summary',
        title: 'Agent run summary',
        content: '{"approvedCount":1}',
      ));

      expect(recorder.bufferedEvents.single.status, 'completed');
    });
  });
}

class _FakeAgentTraceRepository implements AgentTraceRepository {
  final bool throwOnSave;
  final List<AgentTraceEvent> saved = [];

  _FakeAgentTraceRepository({this.throwOnSave = false});

  @override
  Future<void> deleteAgentTraceEvents(String runId) async {}

  @override
  Future<List<AgentTraceEvent>> loadAgentTraceEvents(String runId) async {
    return saved.where((event) => event.runId == runId).toList();
  }

  @override
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) async {
    return saved
        .where((event) => event.chatId == chatId)
        .map((event) => event.runId)
        .toSet()
        .take(limit)
        .toList();
  }

  @override
  Future<void> saveAgentTraceEvent(AgentTraceEvent event) async {
    await saveAgentTraceEvents([event]);
  }

  @override
  Future<void> saveAgentTraceEvents(List<AgentTraceEvent> events) async {
    if (throwOnSave) throw StateError('save failed');
    saved.addAll(events);
  }
}
