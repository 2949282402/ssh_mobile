import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/multi_agent_coordinator.dart';

void main() {
  group('MultiAgentCoordinator policy', () {
    test('triggers for complex server maintenance requests', () {
      const coordinator = MultiAgentCoordinator();

      final decision = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {
            'role': 'user',
            'content': '帮我排查 SSH 服务器性能问题并生成运维报告',
          },
        ],
      );

      expect(decision.enabled, isTrue);
      expect(decision.reason, 'complex_signal');
    });

    test('skips simple or explicitly single-agent requests', () {
      const coordinator = MultiAgentCoordinator();

      final simple = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      final optedOut = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': '快速回答，不要多 agent'},
        ],
      );

      expect(simple.enabled, isFalse);
      expect(simple.reason, 'simple_request');
      expect(optedOut.enabled, isFalse);
      expect(optedOut.reason, 'user_opted_out');
    });

    test('honors disabled settings', () {
      const coordinator = MultiAgentCoordinator();

      final decision = coordinator.shouldCollaborate(
        enabled: false,
        messages: const [
          {'role': 'user', 'content': 'debug a complex SFTP issue'},
        ],
      );

      expect(decision.enabled, isFalse);
      expect(decision.reason, 'disabled_by_settings');
    });
  });

  group('MultiAgentCoordinator execution', () {
    test('runs capped helper roles without tool definitions', () async {
      const coordinator = MultiAgentCoordinator();
      final roles = <String>[];
      final roleMessages = <List<Map<String, dynamic>>>[];

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 99,
        messages: const [
          {'role': 'user', 'content': 'Implement and review an SSH fix'},
        ],
        complete: (role, messages) async {
          roles.add(role.name);
          roleMessages.add(messages);
          return 'advice from ${role.label}';
        },
      );

      expect(result, isNotNull);
      expect(result!.agentCount, 4);
      expect(roles, ['planner', 'operator', 'reviewer', 'summarizer']);
      expect(result.memoryContent, contains('Planner'));
      for (final messages in roleMessages) {
        for (final message in messages) {
          expect(message.containsKey('tools'), isFalse);
          expect(message.containsKey('tool_choice'), isFalse);
        }
      }
    });

    test('redacts helper output and degrades on partial failure', () async {
      const coordinator = MultiAgentCoordinator();

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 3,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        complete: (role, messages) async {
          if (role.name == 'operator') {
            throw StateError('password=supersecret');
          }
          return 'check password=supersecret in logs';
        },
      );

      expect(result, isNotNull);
      expect(result!.memoryContent, contains('[REDACTED]'));
      expect(result.memoryContent, isNot(contains('supersecret')));
      expect(result.traceContent, contains('Helper failed'));
      expect(result.traceContent, isNot(contains('supersecret')));
    });

    test('returns null when policy skips collaboration', () async {
      const coordinator = MultiAgentCoordinator();
      var called = false;

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 3,
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        complete: (role, messages) async {
          called = true;
          return jsonEncode({'role': role.name});
        },
      );

      expect(result, isNull);
      expect(called, isFalse);
    });
  });

  test('normalizes max agent count', () {
    expect(AiMultiAgentMaxAgents.normalize(null), 3);
    expect(AiMultiAgentMaxAgents.normalize(1), 2);
    expect(AiMultiAgentMaxAgents.normalize(3), 3);
    expect(AiMultiAgentMaxAgents.normalize(99), 4);
  });
}
