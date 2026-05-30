import 'dart:async';
import 'dart:convert';

import 'app_log_service.dart';
import 'tool_secret_policy.dart';

class SubAgentThinkingSettings {
  final bool thinkingEnabled;
  final String reasoningEffort;

  const SubAgentThinkingSettings({
    required this.thinkingEnabled,
    required this.reasoningEffort,
  });
}

typedef MultiAgentClassificationCompletion = Future<String> Function(
  List<Map<String, dynamic>> messages,
);

typedef MultiAgentCompletion = Future<String> Function(
  MultiAgentRole role,
  List<Map<String, dynamic>> messages, {
  required SubAgentThinkingSettings thinkingSettings,
});

abstract interface class MultiAgentCoordinatorAdapter {
  Future<MultiAgentRunResult?> run({
    required List<Map<String, dynamic>> messages,
    required bool enabled,
    required int maxAgents,
    required MultiAgentCompletion complete,
    required MultiAgentClassificationCompletion classify,
    void Function()? checkCancelled,
  });
}

class MultiAgentCoordinator implements MultiAgentCoordinatorAdapter {
  static const int maxContextChars = 12000;
  static const int maxAgentOutputChars = 1800;

  final ToolSecretPolicy secretPolicy;
  final int retryBackoffMultiplierMs;

  const MultiAgentCoordinator({
    this.secretPolicy = const ToolSecretPolicy(),
    this.retryBackoffMultiplierMs = 500,
  });

  @override
  Future<MultiAgentRunResult?> run({
    required List<Map<String, dynamic>> messages,
    required bool enabled,
    required int maxAgents,
    required MultiAgentCompletion complete,
    required MultiAgentClassificationCompletion classify,
    void Function()? checkCancelled,
  }) async {
    checkCancelled?.call();
    final decision = shouldCollaborate(
      messages: messages,
      enabled: enabled,
    );
    if (!decision.enabled) {
      AppLogService.instance.info(
        'LLM multi-agent collaboration skipped by pre-check',
        details: decision.reason,
      );
      return null;
    }

    AppLogService.instance.info(
      'LLM multi-agent classification starting',
      details: 'preCheckReason=${decision.reason}',
    );

    final classification = await _classifyRequest(
      messages: messages,
      classify: classify,
      maxAgents: maxAgents,
    );

    checkCancelled?.call();

    if (!classification.shouldCollaborate) {
      AppLogService.instance.info(
        'LLM multi-agent collaboration skipped by classification',
        details: classification.reason,
      );
      return null;
    }

    final roles = _rolesFor(classification.agentCount);
    final latestUser = _latestUserContent(messages);
    final contextText = _recentConversationText(messages);
    AppLogService.instance.info(
      'LLM multi-agent collaboration started with dynamic settings',
      details:
          'roles=${roles.map((role) => role.name).join(',')} thinkingEnabled=${classification.thinkingEnabled} reasoningEffort=${classification.reasoningEffort} reason=${classification.reason}',
    );

    final thinkingSettings = SubAgentThinkingSettings(
      thinkingEnabled: classification.thinkingEnabled,
      reasoningEffort: classification.reasoningEffort,
    );

    final futures = [
      for (final role in roles)
        _runRole(
          role: role,
          latestUser: latestUser,
          contextText: contextText,
          complete: complete,
          thinkingSettings: thinkingSettings,
          checkCancelled: checkCancelled,
        ),
    ];
    final outputs = await Future.wait(futures);
    checkCancelled?.call();

    final successful = outputs.where((output) => output.succeeded).toList();
    if (successful.isEmpty) {
      AppLogService.instance.warning(
        'LLM multi-agent collaboration produced no successful outputs',
        details: outputs.map((output) => output.traceLine).join(' | '),
      );
      return MultiAgentRunResult(
        agentCount: roles.length,
        memoryContent:
            'Multi-agent collaboration was attempted, but every helper failed. Continue with the primary assistant only.',
        traceContent: _traceContent(outputs),
      );
    }

    final memory = StringBuffer('Multi-agent collaboration summary:\n');
    for (final output in successful) {
      memory.writeln('- ${output.role.label}: ${output.content}');
    }
    memory.writeln(
      '\nUse this as advisory context only. The primary assistant remains responsible for any tool calls, approvals, and final answer.',
    );

    final result = MultiAgentRunResult(
      agentCount: roles.length,
      memoryContent: secretPolicy.redactText(memory.toString().trim()),
      traceContent: _traceContent(outputs),
    );
    AppLogService.instance.info(
      'LLM multi-agent collaboration completed',
      details:
          'roles=${roles.length} successful=${successful.length} memoryChars=${result.memoryContent.length}',
    );
    return result;
  }

  MultiAgentDecision shouldCollaborate({
    required List<Map<String, dynamic>> messages,
    required bool enabled,
  }) {
    if (!enabled) {
      return const MultiAgentDecision.disabled('disabled_by_settings');
    }
    final latestUser = _latestUserContent(messages).toLowerCase();
    if (latestUser.trim().isEmpty) {
      return const MultiAgentDecision.disabled('no_user_request');
    }
    const optOut = [
      'single agent',
      'no multi agent',
      'no multi-agent',
      'do not use multi agent',
      'do not use multi-agent',
      'quick answer',
      'fast answer',
      '不要多agent',
      '不要多 agent',
      '不用多agent',
      '不用多 agent',
      '单agent',
      '单 agent',
      '快速回答',
    ];
    if (optOut.any(latestUser.contains)) {
      return const MultiAgentDecision.disabled('user_opted_out');
    }

    const complexSignals = [
      'troubleshoot',
      'diagnose',
      'debug',
      'fix',
      'implement',
      'add ',
      'build',
      'optimize',
      'audit',
      'review',
      'plan',
      'refactor',
      'migrate',
      'report',
      'investigate',
      'analyze',
      'root cause',
      'multi-step',
      'multiple servers',
      'ssh',
      'sftp',
      'logs',
      'performance',
      'monitor',
      'server',
      '排查',
      '诊断',
      '调试',
      '修复',
      '实现',
      '加入',
      '增加',
      '构建',
      '优化',
      '审计',
      '评审',
      '规划',
      '计划',
      '重构',
      '迁移',
      '报告',
      '调查',
      '分析',
      '原因',
      '多步骤',
      '多服务器',
      '日志',
      '性能',
      '监控',
      '服务器',
      '运维',
    ];
    if (complexSignals.any(latestUser.contains)) {
      return const MultiAgentDecision.enabled('complex_signal');
    }
    if (latestUser.length >= 120 && latestUser.contains('?')) {
      return const MultiAgentDecision.enabled('long_question');
    }
    if (latestUser.length >= 180) {
      return const MultiAgentDecision.enabled('long_request');
    }
    return const MultiAgentDecision.disabled('simple_request');
  }

  Future<_RoleOutput> _runRole({
    required MultiAgentRole role,
    required String latestUser,
    required String contextText,
    required MultiAgentCompletion complete,
    required SubAgentThinkingSettings thinkingSettings,
    void Function()? checkCancelled,
  }) async {
    int attempts = 0;
    const maxRetries = 3;

    while (true) {
      try {
        checkCancelled?.call();
        final raw = await complete(
          role,
          _messagesForRole(
            role: role,
            latestUser: latestUser,
            contextText: contextText,
          ),
          thinkingSettings: thinkingSettings,
        ).timeout(const Duration(minutes: 5));
        checkCancelled?.call();
        final content = _truncate(secretPolicy.redactText(raw.trim()));
        return _RoleOutput.success(role, content);
      } catch (e, stackTrace) {
        // Bubble up cancellation exceptions immediately.
        try {
          checkCancelled?.call();
        } catch (_) {
          rethrow;
        }

        if (attempts < maxRetries) {
          attempts++;
          final backoffMs = retryBackoffMultiplierMs * attempts;
          AppLogService.instance.warning(
            'LLM multi-agent helper failed, retrying in ${backoffMs}ms',
            details:
                'role=${role.name} attempt=$attempts/$maxRetries error=${secretPolicy.redactText(e.toString())}',
          );
          if (backoffMs > 0) {
            await Future.delayed(Duration(milliseconds: backoffMs));
          }
          continue;
        }

        AppLogService.instance.error(
          'LLM multi-agent helper failed after $maxRetries retries',
          error: e,
          stackTrace: stackTrace,
          details: 'role=${role.name}',
        );
        return _RoleOutput.failure(
          role,
          secretPolicy.redactText(e.toString()),
        );
      }
    }
  }

  List<Map<String, dynamic>> _messagesForRole({
    required MultiAgentRole role,
    required String latestUser,
    required String contextText,
  }) {
    return [
      {
        'role': 'system',
        'content': role.systemPrompt,
      },
      {
        'role': 'user',
        'content': secretPolicy.redactText(
          [
            'User request:',
            latestUser,
            '',
            'Recent conversation context:',
            contextText,
            '',
            'Return concise advisory notes for the primary assistant. Do not write the final user-facing answer.',
          ].join('\n'),
        ),
      },
    ];
  }

  List<MultiAgentRole> _rolesFor(int requestedMaxAgents) {
    final maxAgents = AiMultiAgentMaxAgents.normalize(requestedMaxAgents);
    const roles = [
      MultiAgentRole(
        name: 'planner',
        label: 'Planner',
        systemPrompt:
            'You are a planning helper inside SSH Mobile. Break the user request into a safe, efficient sequence. Do not call tools, request secrets, or produce a final answer. Keep output brief.',
      ),
      MultiAgentRole(
        name: 'operator',
        label: 'Operator',
        systemPrompt:
            'You are an operations helper inside SSH Mobile. Suggest safe evidence to gather, likely SSH/SFTP/client tools the primary assistant may use, and approval-sensitive actions. Do not call tools yourself. Keep output brief.',
      ),
      MultiAgentRole(
        name: 'reviewer',
        label: 'Reviewer',
        systemPrompt:
            'You are a risk reviewer inside SSH Mobile. Look for missing checks, security pitfalls, platform mismatches, and user-impact risks. Do not call tools or produce a final answer. Keep output brief.',
      ),
      MultiAgentRole(
        name: 'summarizer',
        label: 'Summarizer',
        systemPrompt:
            'You are a synthesis helper inside SSH Mobile. Identify the shortest useful path and the key facts the primary assistant should preserve. Do not call tools or produce a final answer. Keep output brief.',
      ),
    ];
    return roles.take(maxAgents).toList(growable: false);
  }

  String _latestUserContent(List<Map<String, dynamic>> messages) {
    for (final message in messages.reversed) {
      if (message['role'] != 'user') continue;
      final content = message['content'];
      if (content is String) return secretPolicy.redactText(content);
    }
    return '';
  }

  String _recentConversationText(List<Map<String, dynamic>> messages) {
    final buffer = StringBuffer();
    for (final message in messages.reversed) {
      final role = message['role'];
      if (role == 'system') continue;
      final content = message['content'];
      if (content is! String || content.trim().isEmpty) continue;
      final line = '${role ?? 'message'}: ${secretPolicy.redactText(content)}';
      if (buffer.length + line.length + 2 > maxContextChars) break;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(line);
    }
    final lines = buffer.toString().split('\n\n').reversed.join('\n\n');
    return lines.trim().isEmpty ? '(no prior context)' : lines;
  }

  String _traceContent(List<_RoleOutput> outputs) {
    final buffer = StringBuffer();
    for (final output in outputs) {
      buffer.writeln('## ${output.role.label}');
      buffer.writeln(output.succeeded ? output.content : output.traceLine);
      buffer.writeln();
    }
    return secretPolicy.redactText(buffer.toString().trim());
  }

  String _truncate(String value) {
    if (value.length <= maxAgentOutputChars) return value;
    return '${value.substring(0, maxAgentOutputChars)}\n...[truncated]';
  }

  Future<_ClassificationDecision> _classifyRequest({
    required List<Map<String, dynamic>> messages,
    required MultiAgentClassificationCompletion classify,
    required int maxAgents,
  }) async {
    try {
      final latestUser = _latestUserContent(messages);
      final contextText = _recentConversationText(messages);

      final classificationMessages = [
        {
          'role': 'system',
          'content': '''You are the Multi-Agent Coordinator for SSH Mobile.
Determine if the user request requires multi-agent collaboration (e.g. complex troubleshooting, code implementations, debugging, multi-step maintenance planning, safety-critical tasks).
Return JSON only:
{
  "shouldCollaborate": true,
  "reason": "brief explanation",
  "thinkingEnabled": true,
  "reasoningEffort": "medium",
  "agentCount": 3
}''',
        },
        {
          'role': 'user',
          'content': 'Request: $latestUser\nContext: $contextText',
        }
      ];

      final rawResult = await classify(classificationMessages)
          .timeout(const Duration(seconds: 5));

      var cleaned = rawResult.trim();
      if (cleaned.startsWith('```')) {
        cleaned = cleaned.replaceFirst(RegExp(r'^```(?:json)?\n?'), '');
        cleaned = cleaned.replaceFirst(RegExp(r'\n?```$'), '');
        cleaned = cleaned.trim();
      }

      final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
      return _ClassificationDecision(
        shouldCollaborate: decoded['shouldCollaborate'] as bool? ?? false,
        reason: decoded['reason'] as String? ?? 'classified',
        thinkingEnabled: decoded['thinkingEnabled'] as bool? ?? false,
        reasoningEffort: decoded['reasoningEffort'] as String? ?? 'low',
        agentCount:
            (decoded['agentCount'] as num?)?.toInt().clamp(2, maxAgents) ?? 2,
      );
    } catch (e) {
      AppLogService.instance.warning(
        'LLM multi-agent classification failed or timed out. Falling back to single-agent execution.',
        details: e.toString(),
      );
      return const _ClassificationDecision.fallback();
    }
  }
}

class MultiAgentDecision {
  final bool enabled;
  final String reason;

  const MultiAgentDecision.enabled(this.reason) : enabled = true;

  const MultiAgentDecision.disabled(this.reason) : enabled = false;
}

class MultiAgentRunResult {
  final int agentCount;
  final String memoryContent;
  final String traceContent;

  const MultiAgentRunResult({
    required this.agentCount,
    required this.memoryContent,
    required this.traceContent,
  });
}

class MultiAgentRole {
  final String name;
  final String label;
  final String systemPrompt;

  const MultiAgentRole({
    required this.name,
    required this.label,
    required this.systemPrompt,
  });
}

class AiMultiAgentMaxAgents {
  static const int defaultValue = 3;
  static const List<int> values = [2, 3, 4];

  static int normalize(int? value) {
    if (value == null) return defaultValue;
    return value.clamp(values.first, values.last).toInt();
  }
}

class _RoleOutput {
  final MultiAgentRole role;
  final String content;
  final bool succeeded;

  const _RoleOutput._({
    required this.role,
    required this.content,
    required this.succeeded,
  });

  factory _RoleOutput.success(MultiAgentRole role, String content) {
    return _RoleOutput._(
      role: role,
      content: content.trim().isEmpty ? '(no advice returned)' : content,
      succeeded: true,
    );
  }

  factory _RoleOutput.failure(MultiAgentRole role, String error) {
    return _RoleOutput._(
      role: role,
      content: error,
      succeeded: false,
    );
  }

  String get traceLine =>
      succeeded ? content : 'Helper failed: ${content.trim()}';
}

class _ClassificationDecision {
  final bool shouldCollaborate;
  final String reason;
  final bool thinkingEnabled;
  final String reasoningEffort;
  final int agentCount;

  const _ClassificationDecision({
    required this.shouldCollaborate,
    required this.reason,
    required this.thinkingEnabled,
    required this.reasoningEffort,
    required this.agentCount,
  });

  const _ClassificationDecision.fallback()
      : shouldCollaborate = false,
        reason = 'fallback_due_to_failure',
        thinkingEnabled = false,
        reasoningEffort = 'low',
        agentCount = 2;
}
