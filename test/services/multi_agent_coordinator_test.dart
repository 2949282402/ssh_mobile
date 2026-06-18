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
            'content': 'Help me troubleshoot an SSH server performance issue.',
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
          {'role': 'user', 'content': 'quick answer, no multi-agent'},
        ],
      );

      expect(simple.enabled, isFalse);
      expect(simple.reason, 'simple_request');
      expect(optedOut.enabled, isFalse);
      expect(optedOut.reason, 'user_opted_out');
    });

    test('detects Chinese complex requests and explicit opt-out phrases', () {
      const coordinator = MultiAgentCoordinator();

      final complex = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': '帮我排查数据库故障并生成运维报告'},
        ],
      );
      final optedOut = coordinator.shouldCollaborate(
        enabled: true,
        messages: const [
          {'role': 'user', 'content': '不要多智能体，快速回答即可'},
        ],
      );

      expect(complex.enabled, isTrue);
      expect(complex.reason, 'complex_signal');
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
          'shouldCollaborate': true,
          'reason': 'complex fix',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 4,
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          roles.add(role.name);
          roleMessages.add(messages);
          if (role.name == 'summarizer') {
            return jsonEncode({
              'summary': 'consolidated helper summary',
              'recommendedActions': ['review planner output'],
              'risks': ['operator drift'],
              'openQuestions': ['need final confirmation'],
            });
          }
          return 'advice from ${role.label}';
        },
      );

      expect(result, isNotNull);
      expect(result!.agentCount, 4);
      expect(roles, ['explore', 'planner', 'operator', 'summarizer']);
      final memory = jsonDecode(result.memoryContent) as Map<String, dynamic>;
      expect(memory['summary'], 'consolidated helper summary');
      expect(memory['recommendedActions'], ['review planner output']);
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
        maxAgents: 4,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        classify: (messages) async => jsonEncode({
          'shouldCollaborate': true,
          'reason': 'debug troubleshooting',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 4,
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
      expect(result.memoryContent, contains('"recommendedActions"'));
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
          'shouldCollaborate': false,
          'reason': 'simple greeting',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 2,
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
        maxAgents: 4,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        classify: (messages) async => jsonEncode({
          'shouldCollaborate': true,
          'reason': 'complex fix',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 4,
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
      expect(operatorCalls, 4);
      expect(result!.traceContent, contains('transient rate limit'));
    });

    test('succeeds after retrying a transient failure', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      var operatorCalls = 0;

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 4,
        messages: const [
          {'role': 'user', 'content': 'debug logs and fix the server'},
        ],
        classify: (messages) async => jsonEncode({
          'shouldCollaborate': true,
          'reason': 'complex fix',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 4,
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
      expect(operatorCalls, 3);
      expect(result!.memoryContent, contains('resolved advice'));
    });

    test('preserves long playbook output in plan mode summarizer results',
        () async {
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
          'shouldCollaborate': true,
          'reason': 'complex plan',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 5,
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
          maxAgents: 4,
          messages: const [
            {'role': 'user', 'content': 'debug logs and fix the server'},
          ],
          classify: (messages) async => jsonEncode({
            'shouldCollaborate': true,
            'reason': 'complex fix',
            'thinkingEnabled': false,
            'reasoningEffort': 'low',
            'agentCount': 4,
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

      expect(operatorCalls, 1);
    });

    test('propagates dynamic classification settings', () async {
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
          'shouldCollaborate': true,
          'reason': 'complex fix',
          'thinkingEnabled': true,
          'reasoningEffort': 'medium',
          'agentCount': 3,
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

    test('propagates intermediate analysis contexts through DAG phases',
        () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      final roleReceivedMessages = <String, List<Map<String, dynamic>>>{};

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 5,
        messages: const [
          {'role': 'user', 'content': 'inspect logs and fix system'},
        ],
        classify: (messages) async => jsonEncode({
          'shouldCollaborate': true,
          'reason': 'multi-phase troubleshooting',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 5,
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          roleReceivedMessages[role.name] = messages;
          if (role.name == 'summarizer') {
            return jsonEncode({
              'summary': 'merged findings',
              'recommendedActions': ['apply operator fix'],
              'risks': ['needs reviewer sign-off'],
              'openQuestions': [],
            });
          }
          return 'mock output from ${role.label}';
        },
      );

      expect(result, isNotNull);
      expect(result!.agentCount, 5);

      final exploreContent =
          roleReceivedMessages['explore']!.last['content'] as String;
      final plannerContent =
          roleReceivedMessages['planner']!.last['content'] as String;
      final operatorContent =
          roleReceivedMessages['operator']!.last['content'] as String;
      final reviewerContent =
          roleReceivedMessages['reviewer']!.last['content'] as String;
      final summarizerContent =
          roleReceivedMessages['summarizer']!.last['content'] as String;

      expect(exploreContent, isNot(contains('mock output from Planner')));
      expect(plannerContent, isNot(contains('mock output from Explore')));
      expect(operatorContent, contains('mock output from Explore'));
      expect(operatorContent, contains('mock output from Planner'));
      expect(reviewerContent, isNot(contains('mock output from Explore')));
      expect(reviewerContent, contains('mock output from Planner'));
      expect(reviewerContent, contains('mock output from Operator'));
      expect(summarizerContent, contains('mock output from Explore'));
      expect(summarizerContent, contains('mock output from Reviewer'));
    });

    test('returns structured summarizer memory as JSON', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 4,
        messages: const [
          {'role': 'user', 'content': 'review and summarize the rollout plan'},
        ],
        classify: (messages) async => jsonEncode({
          'shouldCollaborate': true,
          'reason': 'structured summary',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 4,
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          if (role.name == 'summarizer') {
            return jsonEncode({
              'summary': 'helper consensus',
              'recommendedActions': ['run smoke tests'],
              'risks': ['stale config'],
              'openQuestions': ['which shard goes first'],
            });
          }
          return 'analysis from ${role.label}';
        },
      );

      expect(result, isNotNull);
      final decoded = jsonDecode(result!.memoryContent) as Map<String, dynamic>;
      expect(decoded['summary'], 'helper consensus');
      expect(decoded['recommendedActions'], ['run smoke tests']);
      expect(decoded['risks'], ['stale config']);
      expect(decoded['openQuestions'], ['which shard goes first']);
    });

    test('gracefully falls back when classification returns invalid JSON',
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
        expect(
          e.toString(),
          isNot(contains('cancelled exception during classify')),
        );
      }

      expect(completeCalled, isFalse);
    });
    test('triggers reviewer for high-risk Chinese requests', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      final roles = <String>[];

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 4,
        messages: const [
          {'role': 'user', 'content': '帮我删除服务器上的旧日志文件'},
        ],
        classify: (messages) async => jsonEncode({
          'shouldCollaborate': true,
          'reason': 'high-risk chinese action',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 3,
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          roles.add(role.name);
          if (role.name == 'summarizer') {
            return jsonEncode({
              'summary': 'done',
              'recommendedActions': [],
              'risks': [],
              'openQuestions': [],
            });
          }
          return 'advice';
        },
      );

      expect(result, isNotNull);
      expect(roles, contains('reviewer'));
    });

    test('does not trigger reviewer for low-risk Chinese requests', () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      final roles = <String>[];

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 4,
        messages: const [
          {'role': 'user', 'content': '帮我排查服务器的当前语言设置'},
        ],
        classify: (messages) async => jsonEncode({
          'shouldCollaborate': true,
          'reason': 'low-risk query',
          'thinkingEnabled': false,
          'reasoningEffort': 'low',
          'agentCount': 3,
        }),
        complete: (role, messages, {required thinkingSettings}) async {
          roles.add(role.name);
          if (role.name == 'summarizer') {
            return jsonEncode({
              'summary': 'done',
              'recommendedActions': [],
              'risks': [],
              'openQuestions': [],
            });
          }
          return 'advice';
        },
      );

      expect(result, isNotNull);
      expect(roles, isNot(contains('reviewer')));
    });

    test(
        'postToolFailure trigger runs only reviewer and summarizer with postToolContext',
        () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      final roles = <String>[];
      var summarizerReceivedContext = '';

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 5,
        trigger: MultiAgentTrigger.postToolFailure,
        postToolContext: 'Failed tool: run_command with exit code 127',
        messages: const [
          {'role': 'user', 'content': 'inspect logs and fix system'},
        ],
        classify: (messages) async => '{}', // 因为是非 preflight，这不会被调用
        complete: (role, messages, {required thinkingSettings}) async {
          roles.add(role.name);
          if (role.name == 'summarizer') {
            summarizerReceivedContext = messages.last['content'] as String;
            return jsonEncode({
              'summary': 'fixed',
              'recommendedActions': [],
              'risks': [],
              'openQuestions': [],
            });
          }
          return 'reviewer advice';
        },
      );

      expect(result, isNotNull);
      // 确认只执行了 reviewer 和 summarizer
      expect(roles, containsAll(['reviewer', 'summarizer']));
      expect(roles, isNot(contains('explore')));
      expect(roles, isNot(contains('planner')));
      expect(roles, isNot(contains('operator')));

      // 确认 postToolContext 传给了 summarizer
      expect(summarizerReceivedContext,
          contains('Failed tool: run_command with exit code 127'));
    });

    test(
        'postBudgetAudit trigger runs only reviewer and summarizer with postToolContext',
        () async {
      const coordinator = MultiAgentCoordinator(retryBackoffMultiplierMs: 0);
      final roles = <String>[];
      var summarizerReceivedContext = '';

      final result = await coordinator.run(
        enabled: true,
        maxAgents: 5,
        trigger: MultiAgentTrigger.postBudgetAudit,
        postToolContext: 'Budget audit rejected context info',
        messages: const [
          {'role': 'user', 'content': 'inspect logs and fix system'},
        ],
        classify: (messages) async => '{}',
        complete: (role, messages, {required thinkingSettings}) async {
          roles.add(role.name);
          if (role.name == 'summarizer') {
            summarizerReceivedContext = messages.last['content'] as String;
            return jsonEncode({
              'summary': 'fixed',
              'recommendedActions': [],
              'risks': [],
              'openQuestions': [],
            });
          }
          return 'reviewer advice';
        },
      );

      expect(result, isNotNull);
      expect(roles, containsAll(['reviewer', 'summarizer']));
      expect(roles, isNot(contains('explore')));
      expect(roles, isNot(contains('planner')));
      expect(roles, isNot(contains('operator')));
      expect(summarizerReceivedContext,
          contains('Budget audit rejected context info'));
    });
  });

  test('normalizes max agent count', () {
    expect(AiMultiAgentMaxAgents.normalize(null), 3);
    expect(AiMultiAgentMaxAgents.normalize(1), 2);
    expect(AiMultiAgentMaxAgents.normalize(3), 3);
    expect(AiMultiAgentMaxAgents.normalize(99), 5);
  });
}
