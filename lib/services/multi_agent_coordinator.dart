import 'dart:async';
import 'dart:convert';

import 'app_log_service.dart';
import 'app_settings.dart';
import '../features/ai_chat/services/llm_chat_service.dart';
import 'tool_secret_policy.dart';

class SubAgentThinkingSettings {
  final bool thinkingEnabled;
  final String reasoningEffort;

  const SubAgentThinkingSettings({
    required this.thinkingEnabled,
    required this.reasoningEffort,
  });
}

typedef MultiAgentClassificationCompletion =
    Future<String> Function(List<Map<String, dynamic>> messages);

typedef MultiAgentCompletion =
    Future<String> Function(
      MultiAgentRole role,
      List<Map<String, dynamic>> messages, {
      required SubAgentThinkingSettings thinkingSettings,
    });

enum MultiAgentTrigger {
  preflight,
  planReview,
  postToolFailure,
  postApprovalRejection,
  postBudgetAudit,
  postLoopGuard,
}

abstract interface class MultiAgentCoordinatorAdapter {
  Future<MultiAgentRunResult?> run({
    required List<Map<String, dynamic>> messages,
    required bool enabled,
    required int maxAgents,
    required MultiAgentCompletion complete,
    required MultiAgentClassificationCompletion classify,
    void Function()? checkCancelled,
    AppLanguage language = AppLanguage.zh,
    String? plannerPrompt,
    String? operatorPrompt,
    String? explorePrompt,
    String? reviewerPrompt,
    String? summarizerPrompt,
    String? coordinatorPrompt,
    bool planMode = false,
    MultiAgentTrigger trigger = MultiAgentTrigger.preflight,
    String? postToolContext,
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
    AppLanguage language = AppLanguage.zh,
    String? plannerPrompt,
    String? operatorPrompt,
    String? explorePrompt,
    String? reviewerPrompt,
    String? summarizerPrompt,
    String? coordinatorPrompt,
    bool planMode = false,
    MultiAgentTrigger trigger = MultiAgentTrigger.preflight,
    String? postToolContext,
  }) async {
    checkCancelled?.call();

    final List<MultiAgentRole> roles;
    final bool thinkingEnabled;
    final String reasoningEffort;
    final String collabReason;
    int preflightAgentCount = 2;

    if (trigger == MultiAgentTrigger.preflight) {
      final decision = shouldCollaborate(messages: messages, enabled: enabled);
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
        checkCancelled: checkCancelled,
        language: language,
        coordinatorPrompt: coordinatorPrompt,
      );

      checkCancelled?.call();

      if (!classification.shouldCollaborate) {
        AppLogService.instance.info(
          'LLM multi-agent collaboration skipped by classification',
          details: classification.reason,
        );
        return null;
      }

      preflightAgentCount = classification.agentCount;
      roles = _rolesFor(
        classification.agentCount,
        language: language,
        plannerPrompt: plannerPrompt,
        operatorPrompt: operatorPrompt,
        explorePrompt: explorePrompt,
        reviewerPrompt: reviewerPrompt,
        summarizerPrompt: summarizerPrompt,
      );
      thinkingEnabled = classification.thinkingEnabled;
      reasoningEffort = classification.reasoningEffort;
      collabReason = classification.reason;
    } else {
      final allRoles = _rolesFor(
        5,
        language: language,
        plannerPrompt: plannerPrompt,
        operatorPrompt: operatorPrompt,
        explorePrompt: explorePrompt,
        reviewerPrompt: reviewerPrompt,
        summarizerPrompt: summarizerPrompt,
      );
      if (trigger == MultiAgentTrigger.planReview) {
        roles = allRoles
            .where(
              (r) =>
                  r.name == 'planner' ||
                  r.name == 'reviewer' ||
                  r.name == 'summarizer',
            )
            .toList();
      } else {
        roles = allRoles
            .where((r) => r.name == 'reviewer' || r.name == 'summarizer')
            .toList();
      }
      thinkingEnabled = false;
      reasoningEffort = 'low';
      collabReason = 'post_tool_trigger_${trigger.name}';
    }

    final latestUser = _latestUserContent(messages);
    final contextText = _recentConversationText(messages);
    AppLogService.instance.info(
      'LLM multi-agent collaboration started with dynamic settings',
      details:
          'roles=${roles.map((role) => role.name).join(',')} thinkingEnabled=$thinkingEnabled reasoningEffort=$reasoningEffort reason=$collabReason',
    );

    final thinkingSettings = SubAgentThinkingSettings(
      thinkingEnabled: thinkingEnabled,
      reasoningEffort: reasoningEffort,
    );

    final outputs = <_RoleOutput>[];
    final roleMap = {for (final r in roles) r.name: r};

    String? getOutputOf(String roleName) {
      for (final out in outputs) {
        if (out.role.name == roleName && out.succeeded) {
          return out.content;
        }
      }
      return null;
    }

    final parallelRoles = [
      if (roleMap['explore'] != null) roleMap['explore']!,
      if (roleMap['planner'] != null) roleMap['planner']!,
    ];
    if (parallelRoles.isNotEmpty) {
      checkCancelled?.call();
      final parallelOutputs = await Future.wait(
        parallelRoles.map(
          (role) => _runRole(
            role: role,
            latestUser: latestUser,
            contextText: contextText,
            complete: complete,
            thinkingSettings: thinkingSettings,
            checkCancelled: checkCancelled,
            language: language,
          ),
        ),
      );
      outputs.addAll(
        _orderedOutputs(parallelOutputs, const ['explore', 'planner']),
      );
    }

    // --- Phase 1: Explore ---
    final exploreRole = roleMap['explore'];
    if (exploreRole != null &&
        outputs.where((out) => out.role.name == 'explore').isEmpty) {
      checkCancelled?.call();
      final out = await _runRole(
        role: exploreRole,
        latestUser: latestUser,
        contextText: contextText,
        complete: complete,
        thinkingSettings: thinkingSettings,
        checkCancelled: checkCancelled,
        language: language,
      );
      outputs.add(out);
    }

    // --- Phase 2: Planner ---
    final plannerRole = roleMap['planner'];
    if (plannerRole != null &&
        outputs.where((out) => out.role.name == 'planner').isEmpty) {
      checkCancelled?.call();
      final exploreContext = getOutputOf('explore');
      final intermediateContext =
          exploreContext != null && exploreContext.isNotEmpty
          ? (language == AppLanguage.en
                ? 'Explore Agent diagnostics:\n$exploreContext'
                : 'Explore Agent (探索智能体) 的诊断建议：\n$exploreContext')
          : null;

      final out = await _runRole(
        role: plannerRole,
        latestUser: latestUser,
        contextText: contextText,
        intermediateContext: intermediateContext,
        complete: complete,
        thinkingSettings: thinkingSettings,
        checkCancelled: checkCancelled,
        language: language,
      );
      outputs.add(out);
    }

    // --- Phase 3: Operator & Reviewer ---
    // 3.1 Operator
    final operatorRole = roleMap['operator'];
    if (operatorRole != null) {
      checkCancelled?.call();
      final exploreContext = getOutputOf('explore');
      final plannerContext = getOutputOf('planner');
      final buffer = StringBuffer();
      if (exploreContext != null && exploreContext.isNotEmpty) {
        buffer.writeln(
          language == AppLanguage.en
              ? 'Explore Agent diagnostics:\n$exploreContext'
              : 'Explore Agent (探索智能体) 的诊断建议：\n$exploreContext',
        );
      }
      if (plannerContext != null && plannerContext.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.writeln(
          language == AppLanguage.en
              ? 'Planner Agent proposed steps:\n$plannerContext'
              : 'Planner Agent (规划智能体) 提出的执行工作流：\n$plannerContext',
        );
      }
      final intermediateContext = buffer.isNotEmpty ? buffer.toString() : null;

      final out = await _runRole(
        role: operatorRole,
        latestUser: latestUser,
        contextText: contextText,
        intermediateContext: intermediateContext,
        complete: complete,
        thinkingSettings: thinkingSettings,
        checkCancelled: checkCancelled,
        language: language,
      );
      outputs.add(out);
    }

    // 3.2 Reviewer
    final reviewerRole = (trigger != MultiAgentTrigger.preflight)
        ? roleMap['reviewer']
        : (_shouldRunReviewer(
                latestUser: latestUser,
                planMode: planMode,
                agentCount: preflightAgentCount,
              )
              ? (roleMap['reviewer'] ??
                    _rolesFor(
                      5,
                      language: language,
                      plannerPrompt: plannerPrompt,
                      operatorPrompt: operatorPrompt,
                      explorePrompt: explorePrompt,
                      reviewerPrompt: reviewerPrompt,
                      summarizerPrompt: summarizerPrompt,
                    ).firstWhere((role) => role.name == 'reviewer'))
              : null);
    if (reviewerRole != null) {
      checkCancelled?.call();
      final String? finalIntermediateContext;
      if (trigger != MultiAgentTrigger.preflight) {
        finalIntermediateContext = postToolContext;
      } else {
        final plannerContext = getOutputOf('planner');
        final operatorContext = getOutputOf('operator');
        final buffer = StringBuffer();
        if (plannerContext != null && plannerContext.isNotEmpty) {
          buffer.writeln(
            language == AppLanguage.en
                ? 'Planner Agent proposed steps:\n$plannerContext'
                : 'Planner Agent (规划智能体) 提出的执行工作流：\n$plannerContext',
          );
        }
        if (operatorContext != null && operatorContext.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.writeln();
          buffer.writeln(
            language == AppLanguage.en
                ? 'Operator Agent proposed actions and commands:\n$operatorContext'
                : 'Operator Agent (执行智能体) 建议的工具及命令：\n$operatorContext',
          );
        }
        finalIntermediateContext = buffer.isNotEmpty ? buffer.toString() : null;
      }

      final out = await _runRole(
        role: reviewerRole,
        latestUser: latestUser,
        contextText: contextText,
        intermediateContext: finalIntermediateContext,
        complete: complete,
        thinkingSettings: thinkingSettings,
        checkCancelled: checkCancelled,
        language: language,
      );
      outputs.add(out);
    }

    // --- Phase 4: Summarizer ---
    final summarizerRole = roleMap['summarizer'];
    if (summarizerRole != null) {
      checkCancelled?.call();
      final buffer = StringBuffer();
      if (trigger != MultiAgentTrigger.preflight && postToolContext != null) {
        buffer.writeln('=== Post-tool trigger context ===');
        buffer.writeln(postToolContext);
      }
      for (final out in outputs) {
        if (!out.succeeded || out.content.isEmpty) continue;
        if (buffer.isNotEmpty) buffer.writeln('\n');
        buffer.writeln('=== Analysis from ${out.role.label} ===');
        buffer.writeln(out.content);
      }
      final intermediateContext = buffer.isNotEmpty ? buffer.toString() : null;

      final out = await _runRole(
        role: summarizerRole,
        latestUser: latestUser,
        contextText: contextText,
        intermediateContext: intermediateContext,
        complete: complete,
        thinkingSettings: thinkingSettings,
        checkCancelled: checkCancelled,
        language: language,
        allowFullOutput: planMode,
        structuredOutput: !planMode,
      );
      outputs.add(out);
    }

    checkCancelled?.call();

    final successful = outputs.where((output) => output.succeeded).toList();
    final executedAgentCount = outputs.length;
    if (successful.isEmpty) {
      AppLogService.instance.warning(
        'LLM multi-agent collaboration produced no successful outputs',
        details: outputs.map((output) => output.traceLine).join(' | '),
      );
      return MultiAgentRunResult(
        agentCount: executedAgentCount,
        memoryContent: language == AppLanguage.en
            ? 'Multi-agent collaboration was attempted, but every helper failed. Continue with the primary assistant only.'
            : '尝试了多智能体协作，但所有辅助智能体都失败了。仅使用主助手继续。',
        traceContent: _traceContent(outputs),
      );
    }

    if (planMode) {
      final summarizerOut = successful.firstWhere(
        (out) => out.role.name == 'summarizer',
        orElse: () => successful.last,
      );
      final result = MultiAgentRunResult(
        agentCount: executedAgentCount,
        memoryContent: secretPolicy.redactText(summarizerOut.content.trim()),
        traceContent: _traceContent(outputs),
      );
      AppLogService.instance.info(
        'LLM multi-agent plan mode collaboration completed',
        details:
            'roles=$executedAgentCount successful=${successful.length} memoryChars=${result.memoryContent.length}',
      );
      return result;
    }

    final header = language == AppLanguage.en
        ? 'Multi-agent collaboration summary:\n'
        : '多智能体协作概要：\n';
    final footer = language == AppLanguage.en
        ? '\nUse this as advisory context only. The primary assistant remains responsible for any tool calls, approvals, and final answer.'
        : '\n仅作为参考上下文。主助手仍应对任何工具调用、审批和最终回答负责。';

    final memory = StringBuffer(header);
    for (final output in successful) {
      memory.writeln('- ${output.role.label}: ${output.content}');
    }
    memory.writeln(footer);
    final summarizerCandidates = successful
        .where((out) => out.role.name == 'summarizer')
        .toList();
    final summarizerOut = summarizerCandidates.isEmpty
        ? null
        : summarizerCandidates.first;
    final structuredSummary = summarizerOut != null
        ? _parseStructuredSummary(summarizerOut.content, outputs)
        : _fallbackStructuredSummary(
            outputs,
            fallbackSummary: memory.toString().trim(),
          );

    final result = MultiAgentRunResult(
      agentCount: executedAgentCount,
      memoryContent: secretPolicy.redactText(
        jsonEncode(structuredSummary.toJson()),
      ),
      traceContent: _traceContent(outputs),
    );
    AppLogService.instance.info(
      'LLM multi-agent collaboration completed',
      details:
          'roles=$executedAgentCount successful=${successful.length} memoryChars=${result.memoryContent.length}',
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
      '关闭多agent',
      '关闭多 agent',
      '禁用多agent',
      '禁用多 agent',
      '不要多智能体',
      '不用多智能体',
      '关闭多智能体',
      '禁用多智能体',
      '单智能体',
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
      '故障',
      '异常',
      '崩溃',
      '配置',
      '安全',
      '多智能体',
      '部署',
      '数据库',
      '自动运维',
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
    String? intermediateContext,
    required MultiAgentCompletion complete,
    required SubAgentThinkingSettings thinkingSettings,
    void Function()? checkCancelled,
    AppLanguage language = AppLanguage.zh,
    bool allowFullOutput = false,
    bool structuredOutput = false,
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
            intermediateContext: intermediateContext,
            language: language,
            structuredOutput: structuredOutput,
          ),
          thinkingSettings: thinkingSettings,
        );
        checkCancelled?.call();
        final content = secretPolicy.redactText(raw.trim());
        final normalized = allowFullOutput || structuredOutput
            ? content
            : _truncate(content);
        return _RoleOutput.success(role, normalized);
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
        return _RoleOutput.failure(role, secretPolicy.redactText(e.toString()));
      }
    }
  }

  List<Map<String, dynamic>> _messagesForRole({
    required MultiAgentRole role,
    required String latestUser,
    required String contextText,
    String? intermediateContext,
    AppLanguage language = AppLanguage.zh,
    bool structuredOutput = false,
  }) {
    final footer = language == AppLanguage.en
        ? 'Return concise advisory notes for the primary assistant. Do not write the final user-facing answer.'
        : '为主要助手返回简明扼要的咨询建议。不要编写最终面向用户的解答。';
    final outputContract = structuredOutput
        ? (language == AppLanguage.en
              ? 'Return JSON only with keys summary, recommendedActions, risks, and openQuestions. Do not wrap it in Markdown and do not write the final user-facing answer.'
              : '仅返回 JSON，包含 summary、recommendedActions、risks、openQuestions 这四个字段。不要使用 Markdown 包裹，也不要直接编写面向用户的最终回答。')
        : footer;

    final intermediateSection =
        (intermediateContext != null && intermediateContext.trim().isNotEmpty)
        ? intermediateContext.trim()
        : '';

    return [
      {'role': 'system', 'content': role.systemPrompt},
      {
        'role': 'user',
        'content': secretPolicy.redactText(
          [
            'User request:',
            latestUser,
            '',
            if (intermediateSection.isNotEmpty) ...[
              language == AppLanguage.en
                  ? 'Intermediate analysis from other helper agents:'
                  : '来自其他辅助智能体的阶段性分析结果：',
              intermediateSection,
              '',
            ],
            'Recent conversation context:',
            contextText,
            '',
            outputContract,
          ].join('\n'),
        ),
      },
    ];
  }

  List<_RoleOutput> _orderedOutputs(
    Iterable<_RoleOutput> outputs,
    List<String> order,
  ) {
    final ranked = {for (var i = 0; i < order.length; i++) order[i]: i};
    final list = outputs.toList(growable: false);
    list.sort((a, b) {
      final rankA = ranked[a.role.name] ?? order.length;
      final rankB = ranked[b.role.name] ?? order.length;
      return rankA.compareTo(rankB);
    });
    return list;
  }

  bool _shouldRunReviewer({
    required String latestUser,
    required bool planMode,
    required int agentCount,
  }) {
    if (planMode) return true;
    if (agentCount >= 5) return true;
    final request = latestUser.toLowerCase();
    const highRiskSignals = [
      'write',
      'delete',
      'modify',
      'change',
      'restart',
      'deploy',
      'migration',
      'rollback',
      'approval',
      'sftp',
      'run command',
      '写入',
      '删除',
      '修改',
      '更改',
      '重启',
      '部署',
      '迁移',
      '回滚',
      '审批',
    ];
    return highRiskSignals.any(request.contains);
  }

  MultiAgentStructuredSummary _parseStructuredSummary(
    String raw,
    List<_RoleOutput> outputs,
  ) {
    try {
      var cleaned = raw.trim();
      if (cleaned.startsWith('```')) {
        cleaned = cleaned.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
        cleaned = cleaned.replaceFirst(RegExp(r'\s*```$'), '');
      }
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, dynamic>) {
        List<String> readList(String key) {
          final value = decoded[key];
          if (value is! List) return const [];
          return value
              .map((item) => '$item'.trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false);
        }

        final summary = ('${decoded['summary'] ?? ''}').trim();
        if (summary.isNotEmpty) {
          return MultiAgentStructuredSummary(
            summary: summary,
            recommendedActions: readList('recommendedActions'),
            risks: readList('risks'),
            openQuestions: readList('openQuestions'),
          );
        }
      }
    } catch (_) {}
    return _fallbackStructuredSummary(outputs, fallbackSummary: raw.trim());
  }

  MultiAgentStructuredSummary _fallbackStructuredSummary(
    List<_RoleOutput> outputs, {
    String? fallbackSummary,
  }) {
    final successful = outputs.where((output) => output.succeeded).toList();
    final summary = fallbackSummary?.trim().isNotEmpty == true
        ? fallbackSummary!.trim()
        : successful.isEmpty
        ? 'No helper advice returned.'
        : successful
              .map((output) => '${output.role.label}: ${output.content}')
              .join('\n');
    final recommendedActions = successful
        .take(3)
        .map((output) => '${output.role.label}: ${_singleLine(output.content)}')
        .toList(growable: false);
    final risks = outputs
        .where((output) => !output.succeeded)
        .map((output) => '${output.role.label}: ${_singleLine(output.content)}')
        .toList(growable: false);
    return MultiAgentStructuredSummary(
      summary: summary,
      recommendedActions: recommendedActions,
      risks: risks,
      openQuestions: const [],
    );
  }

  String _singleLine(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<MultiAgentRole> _rolesFor(
    int requestedMaxAgents, {
    AppLanguage language = AppLanguage.zh,
    String? plannerPrompt,
    String? operatorPrompt,
    String? explorePrompt,
    String? reviewerPrompt,
    String? summarizerPrompt,
  }) {
    final maxAgents = AiMultiAgentMaxAgents.normalize(requestedMaxAgents);
    final isEn = language == AppLanguage.en;

    final plannerDefault = isEn
        ? '$multiAgentPlannerPromptEnPersona $multiAgentPlannerPromptEnSafety'
        : '$multiAgentPlannerPromptZhPersona $multiAgentPlannerPromptZhSafety';
    final planner = (plannerPrompt != null && plannerPrompt.trim().isNotEmpty)
        ? plannerPrompt.trim()
        : plannerDefault;

    final operatorDefault = isEn
        ? '$multiAgentOperatorPromptEnPersona $multiAgentOperatorPromptEnSafety'
        : '$multiAgentOperatorPromptZhPersona $multiAgentOperatorPromptZhSafety';
    final operator =
        (operatorPrompt != null && operatorPrompt.trim().isNotEmpty)
        ? operatorPrompt.trim()
        : operatorDefault;

    final exploreDefault = isEn
        ? '$multiAgentExplorePromptEnPersona $multiAgentExplorePromptEnSafety'
        : '$multiAgentExplorePromptZhPersona $multiAgentExplorePromptZhSafety';
    final explore = (explorePrompt != null && explorePrompt.trim().isNotEmpty)
        ? explorePrompt.trim()
        : exploreDefault;

    final reviewerDefault = isEn
        ? '$multiAgentReviewerPromptEnPersona $multiAgentReviewerPromptEnSafety'
        : '$multiAgentReviewerPromptZhPersona $multiAgentReviewerPromptZhSafety';
    final reviewer =
        (reviewerPrompt != null && reviewerPrompt.trim().isNotEmpty)
        ? reviewerPrompt.trim()
        : reviewerDefault;

    final summarizerDefault = isEn
        ? '$multiAgentSummarizerPromptEnPersona $multiAgentSummarizerPromptEnSafety'
        : '$multiAgentSummarizerPromptZhPersona $multiAgentSummarizerPromptZhSafety';
    final summarizer =
        (summarizerPrompt != null && summarizerPrompt.trim().isNotEmpty)
        ? summarizerPrompt.trim()
        : summarizerDefault;

    final roles = [
      MultiAgentRole(name: 'explore', label: 'Explore', systemPrompt: explore),
      MultiAgentRole(name: 'planner', label: 'Planner', systemPrompt: planner),
      MultiAgentRole(
        name: 'operator',
        label: 'Operator',
        systemPrompt: operator,
      ),
      MultiAgentRole(
        name: 'reviewer',
        label: 'Reviewer',
        systemPrompt: reviewer,
      ),
      MultiAgentRole(
        name: 'summarizer',
        label: 'Summarizer',
        systemPrompt: summarizer,
      ),
    ];
    switch (maxAgents) {
      case 2:
        return [
          roles.firstWhere((role) => role.name == 'planner'),
          roles.firstWhere((role) => role.name == 'summarizer'),
        ];
      case 3:
        return [
          roles.firstWhere((role) => role.name == 'explore'),
          roles.firstWhere((role) => role.name == 'planner'),
          roles.firstWhere((role) => role.name == 'summarizer'),
        ];
      case 4:
        return [
          roles.firstWhere((role) => role.name == 'explore'),
          roles.firstWhere((role) => role.name == 'planner'),
          roles.firstWhere((role) => role.name == 'operator'),
          roles.firstWhere((role) => role.name == 'summarizer'),
        ];
      default:
        return roles;
    }
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
    void Function()? checkCancelled,
    AppLanguage language = AppLanguage.zh,
    String? coordinatorPrompt,
  }) async {
    try {
      checkCancelled?.call();
      final latestUser = _latestUserContent(messages);
      final contextText = _recentConversationText(messages);

      final coordinator =
          (coordinatorPrompt != null && coordinatorPrompt.trim().isNotEmpty)
          ? coordinatorPrompt.trim()
          : (language == AppLanguage.en
                ? multiAgentCoordinatorPromptEn
                : multiAgentCoordinatorPromptZh);

      final classificationMessages = [
        {'role': 'system', 'content': coordinator},
        {
          'role': 'user',
          'content': 'Request: $latestUser\nContext: $contextText',
        },
      ];

      final rawResult = await classify(classificationMessages);

      checkCancelled?.call();

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
      try {
        checkCancelled?.call();
      } catch (_) {
        rethrow;
      }
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

class MultiAgentStructuredSummary {
  final String summary;
  final List<String> recommendedActions;
  final List<String> risks;
  final List<String> openQuestions;

  const MultiAgentStructuredSummary({
    required this.summary,
    this.recommendedActions = const [],
    this.risks = const [],
    this.openQuestions = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'summary': summary,
      'recommendedActions': recommendedActions,
      'risks': risks,
      'openQuestions': openQuestions,
    };
  }
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
  static const List<int> values = [2, 3, 4, 5];

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
    return _RoleOutput._(role: role, content: error, succeeded: false);
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
