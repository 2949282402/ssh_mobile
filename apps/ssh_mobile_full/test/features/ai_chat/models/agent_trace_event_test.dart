import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/models/agent_trace_event.dart';

void main() {
  group('AgentTraceEvent', () {
    test('roundtrips json and defaults status', () {
      final now = DateTime.utc(2026, 6, 22, 10);
      final event = AgentTraceEvent(
        id: 'trace-1',
        runId: 'run-1',
        chatId: 'chat-1',
        createdAt: now,
        sequence: 2,
        kind: 'tool_request',
        title: 'Tool request: run_command',
        content: '{"tool":"run_command"}',
        toolName: 'run_command',
      );

      final decoded = AgentTraceEvent.fromJson(event.toJson());

      expect(decoded.id, 'trace-1');
      expect(decoded.runId, 'run-1');
      expect(decoded.chatId, 'chat-1');
      expect(decoded.createdAt, now);
      expect(decoded.sequence, 2);
      expect(decoded.status, 'info');
      expect(decoded.toolName, 'run_command');
    });

    test('copyWith preserves ordering fields and changes content', () {
      final now = DateTime.utc(2026, 6, 22, 10);
      final event = AgentTraceEvent(
        runId: 'run-1',
        chatId: 'chat-1',
        createdAt: now,
        sequence: 1,
        kind: 'approval',
        title: 'Approval',
        content: 'requested',
      );

      final copy = event.copyWith(sequence: 3, content: 'approved');

      expect(copy.id, event.id);
      expect(copy.sequence, 3);
      expect(copy.content, 'approved');
      expect(copy.createdAt, now);
    });

    test('truncates oversized content and marks truncated', () {
      final event = AgentTraceEvent(
        runId: 'run-1',
        chatId: 'chat-1',
        createdAt: DateTime.utc(2026, 6, 22),
        sequence: 0,
        kind: 'tool_result',
        title: 'Tool result',
        content: 'x' * (agentTraceContentMaxChars + 100),
      );

      expect(event.content.length, agentTraceContentMaxChars);
      expect(event.content, contains('[trace content truncated]'));
      expect(event.truncated, isTrue);
    });

    test('events sort by sequence', () {
      final now = DateTime.utc(2026, 6, 22);
      final events = [
        AgentTraceEvent(
          runId: 'run-1',
          chatId: 'chat-1',
          createdAt: now,
          sequence: 2,
          kind: 'info',
          title: 'Second',
          content: '',
        ),
        AgentTraceEvent(
          runId: 'run-1',
          chatId: 'chat-1',
          createdAt: now,
          sequence: 1,
          kind: 'info',
          title: 'First',
          content: '',
        ),
      ]..sort((a, b) => a.sequence.compareTo(b.sequence));

      expect(events.map((event) => event.title), ['First', 'Second']);
    });
  });
}
