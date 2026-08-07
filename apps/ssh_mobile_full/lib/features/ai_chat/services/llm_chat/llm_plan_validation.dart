part of '../llm_chat_service.dart';

extension LlmChatServicePlanValidation on LlmChatService {
  Future<bool> _requestAgentLoopRoundApproval({
    required AgentLoopGuard guard,
    required Future<AiToolApprovalDecision> Function(
      AiToolApprovalRequest request,
    )?
    requestToolApproval,
    required void Function(LlmTraceEvent event)? onTrace,
  }) async {
    final currentLimit = guard.modelRoundLimit;
    if (currentLimit == null) return true;
    final extension = guard.extensionSize;
    final nextLimit = currentLimit + extension;
    final tracePayload = {
      'approvalType': 'agent_loop_round_budget',
      'agentLoopMode': guard.mode,
      'modelRoundsUsed': guard.modelRoundsUsed,
      'currentLimit': currentLimit,
      'extensionRounds': extension,
      'nextLimit': nextLimit,
      'loopExtensionCount': guard.loopExtensionCount,
      'toolBudgetUnchanged': true,
    };

    onTrace?.call(
      LlmTraceEvent(
        kind: 'agent_loop_round_budget_requested',
        title: 'Agent loop round extension requested',
        content: _prettyJson(tracePayload),
      ),
    );

    if (requestToolApproval == null) {
      guard.markStopped('approval_unavailable');
      onTrace?.call(
        LlmTraceEvent(
          kind: 'agent_loop_round_budget_unavailable',
          title: 'Agent loop round approval unavailable',
          content: _prettyJson(tracePayload),
        ),
      );
      return false;
    }

    final decision = await requestToolApproval(
      AiToolApprovalRequest(
        toolName: 'agent_loop_round_budget',
        approvalType: 'agent_loop_round_budget',
        connectionId: 'local',
        connectionName: 'System',
        command:
            'Extend agent loop round limit from $currentLimit to $nextLimit',
        reason:
            'The primary agent loop reached the ${guard.mode} round limit before finishing. Continue for $extension more model rounds?',
        contentPreview:
            'Primary model rounds used: ${guard.modelRoundsUsed}/$currentLimit\n'
            'Extension: +$extension rounds\n'
            'Next limit: $nextLimit\n'
            'Tool call budget is unchanged.',
      ),
    );

    if (decision.approved) {
      final approvedLimit = guard.approveExtension();
      onTrace?.call(
        LlmTraceEvent(
          kind: 'agent_loop_round_budget_approved',
          title: 'Agent loop round extension approved',
          content: _prettyJson({
            ...tracePayload,
            'approvedLimit': approvedLimit,
            'loopExtensionCount': guard.loopExtensionCount,
          }),
        ),
      );
      return true;
    }

    guard.markStopped('user_paused');
    onTrace?.call(
      LlmTraceEvent(
        kind: 'agent_loop_round_budget_rejected',
        title: 'Agent loop round extension paused',
        content: _prettyJson({
          ...tracePayload,
          'feedback': decision.feedback,
          'abort': decision.abort,
        }),
      ),
    );
    return false;
  }

  String _agentLoopPausedInstruction(AppLanguage language) {
    if (language == AppLanguage.en) {
      return 'The user paused additional agent loop rounds. Do not call tools again. Summarize the current findings and clearly state what remains unresolved.';
    }
    return '用户已暂停继续增加 Agent 循环轮次。不要再调用工具。请基于已有结果总结当前发现，并明确说明仍未解决的事项。';
  }

  String? _resolveChatId() {
    final executor = toolService;
    if (executor is AiToolService) {
      return executor.clientWebViewSessionId;
    }
    return null;
  }

  Future<bool> _hasPersistedTodoSteps(String? chatId) async {
    if (chatId == null) return false;
    try {
      final chats = await storageService.loadAiChats();
      final chatIndex = chats.indexWhere((c) => c.id == chatId);
      if (chatIndex == -1) return false;
      final chat = chats[chatIndex];
      if (chat.messages.isEmpty) return false;
      final assistantMsg = chat.messages.lastWhere(
        (m) => m.role == 'assistant',
      );
      return assistantMsg.todoSteps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<_PlanValidationOutcome> _validateAndRepairPlanOutput({
    required String initialText,
    required AppLanguage language,
    required AiConnectionSettings settings,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> workingMessages,
    required LlmCancellationToken? cancellationToken,
    required void Function(LlmTraceEvent event)? onTrace,
    required String? chatId,
  }) async {
    final hasSteps = await _hasPersistedTodoSteps(chatId);
    var validation = PlanOutputValidator.validate(
      assistantText: initialText,
      hasPersistedTodoSteps: hasSteps,
    );

    if (validation.isValid) {
      onTrace?.call(
        LlmTraceEvent(
          kind: 'plan_output_validation',
          title: 'Plan output validated successfully',
          content: _prettyJson({
            'status': validation.status.name,
            'hasPersistedTodoSteps': hasSteps,
          }),
        ),
      );
      return _PlanValidationOutcome(
        finalText: initialText,
        validation: validation,
        repaired: false,
        repairFailed: false,
      );
    }

    onTrace?.call(
      LlmTraceEvent(
        kind: 'plan_output_validation',
        title: 'Plan output validation failed',
        content: _prettyJson({
          'status': validation.status.name,
          'reason': validation.reason,
          'hasPersistedTodoSteps': hasSteps,
        }),
      ),
    );

    final repairPrompt = buildPlanOutputRepairPrompt(
      language: language,
      invalidReason: validation.reason ?? 'Unknown validation error',
      previousOutput: initialText,
    );

    final repairMessages = [
      ...workingMessages,
      {'role': 'user', 'content': repairPrompt},
    ];

    final repairBuffer = StringBuffer();
    try {
      await for (final chunk in _streamRepairCompletion(
        settings: settings,
        apiKey: apiKey,
        model: model,
        workingMessages: repairMessages,
        cancellationToken: cancellationToken,
      )) {
        repairBuffer.write(chunk);
      }
    } catch (e) {
      return _PlanValidationOutcome(
        finalText: initialText,
        validation: validation,
        repaired: true,
        repairFailed: true,
      );
    }

    final repairText = repairBuffer.toString();
    final repairHasSteps = await _hasPersistedTodoSteps(chatId);
    final repairValidation = PlanOutputValidator.validate(
      assistantText: repairText,
      hasPersistedTodoSteps: repairHasSteps,
    );

    if (repairValidation.isValid) {
      onTrace?.call(
        LlmTraceEvent(
          kind: 'plan_output_validation',
          title: 'Plan output repaired successfully',
          content: _prettyJson({
            'status': repairValidation.status.name,
            'hasPersistedTodoSteps': repairHasSteps,
          }),
        ),
      );
      return _PlanValidationOutcome(
        finalText: repairText,
        validation: repairValidation,
        repaired: true,
        repairFailed: false,
      );
    } else {
      onTrace?.call(
        LlmTraceEvent(
          kind: 'plan_output_validation',
          title: 'Plan output repair failed',
          content: _prettyJson({
            'status': repairValidation.status.name,
            'reason': repairValidation.reason,
            'hasPersistedTodoSteps': repairHasSteps,
          }),
        ),
      );
      final failureNote = language == AppLanguage.en
          ? '\n\nPlan output validation still failed. This plan will remain in Plan Mode. Please regenerate a valid ```playbook JSON block with non-empty steps.\n\n'
          : '\n\n规划输出格式校验仍未通过。当前计划不会自动进入执行模式。请重新生成包含非空 steps 的 ```playbook JSON 代码块。\n\n';
      return _PlanValidationOutcome(
        finalText: '$initialText$failureNote$repairText',
        validation: repairValidation,
        repaired: true,
        repairFailed: true,
      );
    }
  }

  Stream<String> _streamRepairCompletion({
    required AiConnectionSettings settings,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> workingMessages,
    required LlmCancellationToken? cancellationToken,
  }) async* {
    final chunkController = StreamController<String>();
    final provider = LlmProviderFactory.fromSettings(settings);
    Future<void> pumpStream() async {
      try {
        await provider.streamChat(
          LlmProviderRequest(
            baseUrl: settings.baseUrl,
            apiKey: apiKey,
            model: model,
            messages: workingMessages,
            tools: const [],
            includeTools: false,
            deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
            deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
            openAiReasoningEffort: settings.openAiReasoningEffort,
            cancellationToken: cancellationToken,
            onTextDelta: (chunk) {
              cancellationToken?.throwIfCancelled();
              chunkController.add(chunk);
            },
            timeoutSeconds: settings.timeoutSeconds,
          ),
        );
      } catch (e) {
        chunkController.addError(e);
      } finally {
        await chunkController.close();
      }
    }

    unawaited(pumpStream());
    yield* chunkController.stream;
  }
}
