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

    test(
        'triggers and closes correctly for Chinese complex requests and explicit close scenarios',
        () {
      const coordinator = MultiAgentCoordinator();

      // Test triggers for Chinese complex requests
      final complexTrigger1 = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': '系统崩溃了，帮我看一下数据库故障'},
        ],
      );
      final complexTrigger2 = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': '如何配置多智能体自动运维 and 安全部署？'},
        ],
      );

      expect(complexTrigger1.enabled, isTrue);
      expect(complexTrigger1.reason, 'complex_signal');
      expect(complexTrigger2.enabled, isTrue);
      expect(complexTrigger2.reason, 'complex_signal');

      // Test explicit opt-out in Chinese
      final explicitClose1 = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': '禁用多agent，快速回答即可'},
        ],
      );
      final explicitClose2 = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': '不要多智能体，用单智能体回答'},
        ],
      );
      final explicitClose3 = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': '关闭多智能体，谢谢'},
        ],
      );

      expect(explicitClose1.enabled, isFalse);
      expect(explicitClose1.reason, 'user_opted_out');
      expect(explicitClose2.enabled, isFalse);
      expect(explicitClose2.reason, 'user_opted_out');
      expect(explicitClose3.enabled, isFalse);
      expect(explicitClose3.reason, 'user_opted_out');
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
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      final roles = <String>[];
      final roleMessages = <List<Map<String, dynamic>>>[];

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 99,
        messages: const [
          {'role': 'user', 'content': 'Implement and review an SSH fix'},
        ],
        classify: (messages) async => jsonEncode({
          "shouldCollaborate": true,
          "reason": "complex fix",
          "thinkingEnabled": false,
          "reasoningEffort": "low",
          "agentCount": 4
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          roles.add(role.name);
          roleMessages.add(messages);
          return 'advice from ${role.label}';
        },
      );

      expect(result, isNotNull);
      expect(result!.agentCount, 4);
      expect(roles, ['explore', 'planner', 'operator', 'reviewer']);
      expect(result.memoryContent, contains('Planner'));
      for (final messages in roleMessages) {
        for (final message in messages) {
          expect(message.containsKey('tools'), isFalse);
          expect(message.containsKey('tool_choice'), isFalse);
        }
      }
    });

    test('redacts helper output and degrades on partial failure', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 3,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        classify: (messages) async => jsonEncode({
          "shouldCollaborate": true,
          "reason": "debug troubleshooting",
          "thinkingEnabled": false,
          "reasoningEffort": "low",
          "agentCount": 3
        }),
        complete: (role, messages, {required thinkingSettings}) async {
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
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      var called = false;

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 3,
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        classify: (messages) async => jsonEncode({
          "shouldCollaborate": false,
          "reason": "simple greeting",
          "thinkingEnabled": false,
          "reasoningEffort": "low",
          "agentCount": 2
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          called = true;
          return jsonEncode({'role': role.name});
        },
      );

      expect(result, isNull);
      expect(called, isFalse);
    });

    test('retries failed helper roles up to 3 times with backoff', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      var operatorCalls = 0;

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 3,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        classify: (messages) async => jsonEncode({
          "shouldCollaborate": true,
          "reason": "complex fix",
          "thinkingEnabled": false,
          "reasoningEffort": "low",
          "agentCount": 3
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          if (role.name == 'operator') {
            operatorCalls++;
            throw StateError('transient rate limit');
          }
          return 'advice from ${role.label}';
        },
      );

      expect(result, isNotNull);
      expect(operatorCalls, 4); // 1 initial attempt + 3 retries
      expect(result!.traceContent, contains('transient rate limit'));
    });

    test('succeeds after retrying a transient failure', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      var operatorCalls = 0;

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 3,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        classify: (messages) async => jsonEncode({
          "shouldCollaborate": true,
          "reason": "complex fix",
          "thinkingEnabled": false,
          "reasoningEffort": "low",
          "agentCount": 3
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          if (role.name == 'operator') {
            operatorCalls++;
            if (operatorCalls < 3) {
              throw StateError('transient rate limit');
            }
            return 'resolved advice';
          }
          return 'advice from ${role.label}';
        },
      );

      expect(result, isNotNull);
      expect(operatorCalls, 3); // 2 failures + 1 success
      expect(result!.memoryContent, contains('Operator: resolved advice'));
    });

    test('preserves long playbook output in plan mode summarizer results', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      final longCommand = 'echo ${'x' * 2200}';
      final playbook = '''
```playbook
{"steps":[{"name":"Long step","command":"$longCommand","description":"Preserve the full command in plan mode."}]}
```
''';

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 5,
        planMode: true,
        messages: const [
          {'role': 'user', 'content': 'Plan a long maintenance workflow'},
        ],
        classify: (messages) async => jsonEncode({
          "shouldCollaborate": true,
          "reason": "complex plan",
          "thinkingEnabled": false,
          "reasoningEffort": "low",
          "agentCount": 5
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          if (role.name == 'summarizer') {
            return playbook;
          }
          return 'helper output from ${role.name}';
        },
      );

      expect(result, isNotNull);
      expect(result!.memoryContent, contains('```playbook'));
      expect(result.memoryContent, contains(longCommand));
      expect(result.memoryContent, isNot(contains('[truncated]')));
    });

    test('cancellation exits immediately without retrying', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      var operatorCalls = 0;
      var cancelled = false;

      try {
        await coordinator.run(
          enabled: true,
          maxAgents: 3,
          messages: const [
            {'role': 'user', 'content': 'debug logs and fix the server'},
          ],
          classify: (messages) async => jsonEncode({
            "shouldCollaborate": true,
            "reason": "complex fix",
            "thinkingEnabled": false,
            "reasoningEffort": "low",
            "agentCount": 3
          }),
          checkCancelled: () {
            if (cancelled) {
              throw StateError('cancelled');
            }
          },
          complete: (role, messages, {required thinkingSettings}) async {
            if (role.name == 'operator') {
              operatorCalls++;
              cancelled = true;
              throw StateError('some error');
            }
            return 'advice';
          },
        );
        fail('Should have thrown cancellation exception');
      } catch (e) {
        expect(e.toString(), contains('cancelled'));
      }

      expect(operatorCalls, 1); // Only 1 attempt before cancellation exit
    });

    test(
        'propagates dynamic classification settings (thinking and reasoning effort)',
        () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      bool? propagatedThinking;
      String? propagatedEffort;

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 3,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        classify: (messages) async => jsonEncode({
          "shouldCollaborate": true,
          "reason": "complex fix",
          "thinkingEnabled": true,
          "reasoningEffort": "medium",
          "agentCount": 3
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          propagatedThinking = thinkingSettings.thinkingEnabled;
          propagatedEffort = thinkingSettings.reasoningEffort;
          return 'advice from ${role.label}';
        },
      );

      expect(result, isNotNull);
      expect(propagatedThinking, isTrue);
      expect(propagatedEffort, 'medium');
    });

    test('propagates intermediate analysis contexts through cascade phases', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      final roleReceivedMessages = <String, List<Map<String, dynamic>>>{};

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 4,
        messages: const [
          {'role': 'user', 'content': 'inspect logs and fix system'},
        ],
        classify: (messages) async => jsonEncode({
          "shouldCollaborate": true,
          "reason": "multi-phase troubleshooting",
          "thinkingEnabled": false,
          "reasoningEffort": "low",
          "agentCount": 4
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          roleReceivedMessages[role.name] = messages;
          return 'mock output from ${role.label}';
        },
      );

      expect(result, isNotNull);
      expect(result!.agentCount, 4);

      // 验证 Explore 率先执行，无前置依赖
      final exploreMsgs = roleReceivedMessages['explore'];
      expect(exploreMsgs, isNotNull);
      final exploreContent = exploreMsgs!.last['content'] as String;
      expect(exploreContent, isNot(contains('来自其他辅助智能体的阶段性分析结果：')));

      // 验证 Planner 接收 Explore 诊断结果
      final plannerMsgs = roleReceivedMessages['planner'];
      expect(plannerMsgs, isNotNull);
      final plannerContent = plannerMsgs!.last['content'] as String;
      expect(plannerContent, contains('Explore Agent (探索智能体) 的诊断建议：'));
      expect(plannerContent, contains('mock output from Explore'));

      // 验证 Operator 接收 Explore 和 Planner 成果
      final operatorMsgs = roleReceivedMessages['operator'];
      expect(operatorMsgs, isNotNull);
      final operatorContent = operatorMsgs!.last['content'] as String;
      expect(operatorContent, contains('Explore Agent (探索智能体) 的诊断建议：'));
      expect(operatorContent, contains('Planner Agent (规划智能体) 提出的执行工作流：'));
      expect(operatorContent, contains('mock output from Explore'));
      expect(operatorContent, contains('mock output from Planner'));

      // 验证 Reviewer 审计 Planner 和 Operator
      final reviewerMsgs = roleReceivedMessages['reviewer'];
      expect(reviewerMsgs, isNotNull);
      final reviewerContent = reviewerMsgs!.last['content'] as String;
      expect(reviewerContent, isNot(contains('Explore Agent')));
      expect(reviewerContent, contains('Planner Agent (规划智能体) 提出的执行工作流：'));
      expect(reviewerContent, contains('Operator Agent (执行智能体) 建议的工具及命令：'));
      expect(reviewerContent, contains('mock output from Planner'));
      expect(reviewerContent, contains('mock output from Operator'));
    });

    test(
        'gracefully falls back when classification returns invalid JSON or times out',
        () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      var completeCalled = false;

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 3,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        classify: (messages) async =>
            'invalid markdown json ```json {invalid} ```',
        complete: (role, messages, {required thinkingSettings}) async {
          completeCalled = true;
          return 'advice';
        },
      );

      // Should fall back to shouldCollaborate: false, thus returning null and skipping sub-agents
      expect(result, isNull);
      expect(completeCalled, isFalse);
    });

    test('cancellation inside classification phase is propagated immediately',
        () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      var checkCancelledCalled = 0;
      var completeCalled = false;

      try {
        await coordinator.run(
          enabled: true,
          maxAgents: 3,
          messages: const [
            {'role': 'user', 'content': 'debug logs and fix the server'},
          ],
          classify: (messages) async {
            throw StateError('cancelled exception during classify');
          },
          checkCancelled: () {
            checkCancelledCalled++;
            if (checkCancelledCalled >= 2) {
              throw StateError('cancelled');
            }
          },
          complete: (role, messages, {required thinkingSettings}) async {
            completeCalled = true;
            return 'advice';
          },
        );
        fail('Should have thrown cancellation exception');
      } catch (e) {
        expect(e.toString(), contains('cancelled'));
        expect(e.toString(),
            isNot(contains('cancelled exception during classify')));
      }

      expect(completeCalled, isFalse);
    });
  });

  test('normalizes max agent count', () {
    expect(AiMultiAgentMaxAgents.normalize(null), 3);
    expect(AiMultiAgentMaxAgents.normalize(1), 2);
    expect(AiMultiAgentMaxAgents.normalize(3), 3);
    expect(AiMultiAgentMaxAgents.normalize(99), 5);
  });
}
