part of '../llm_chat_service.dart';

enum _ToolPreflightDisposition { proceed, blocked, planBlocked }

/// 将工具结果统一折叠到 provider message、system hint、ledger 和 trace。
final class _ToolResultRecorder {
  const _ToolResultRecorder({
    required this.chatService,
    required this.toolBudget,
    required this.toolLedger,
  });

  final LlmChatService chatService;
  final LlmToolBudgetController toolBudget;
  final List<LlmToolLedgerEntry> toolLedger;

  ToolResultQuality record({
    required StreamingToolCall call,
    required LlmProviderAdapter provider,
    required List<Map<String, dynamic>> workingMessages,
    required String signature,
    required Object? redactedArguments,
    required String result,
    required String outcome,
    required AppLanguage language,
    required void Function(LlmTraceEvent event)? onTrace,
    required int index,
    bool approvalRequired = false,
    bool approved = false,
    bool cacheHit = false,
    bool dedupBlocked = false,
    ToolResultQuality? qualityOverride,
    bool includeHint = true,
    bool? failedOverride,
  }) {
    chatService._emitToolResultTrace(
      onTrace,
      call.name,
      result,
      outcome: outcome,
      cacheHit: cacheHit,
      dedupBlocked: dedupBlocked,
    );
    workingMessages.add(
      provider.buildToolResultMessage(
        call: LlmProviderToolCall(
          id: call.id,
          name: call.name,
          argumentsJson: call.arguments,
        ),
        result: result,
      ),
    );
    final quality =
        qualityOverride ??
        ToolResultClassifier.classify(
          toolName: call.name,
          resultJson: result,
          outcome: outcome,
          approvalRequired: approvalRequired,
          approved: approved,
          cacheHit: cacheHit,
          dedupBlocked: dedupBlocked,
        );
    if (includeHint) {
      final hint = ToolResultClassifier.getSystemHint(
        call.name,
        quality,
        language,
      );
      if (hint != null)
        workingMessages.add({'role': 'system', 'content': hint});
    }
    toolLedger.add(
      LlmToolLedgerEntry(
        index: index,
        toolName: call.name,
        signature: signature,
        argumentsPreview: chatService._toolSecretPolicy.previewText(
          chatService._prettyJson(redactedArguments),
          maxChars: 400,
        ),
        outcome: outcome,
        approvalRequired: approvalRequired,
        approved: approved,
        failed:
            failedOverride ?? (outcome != 'success' && outcome != 'cache_hit'),
        emptyResult: chatService._looksLikeEmptyToolResult(result),
        cacheHit: cacheHit,
        dedupBlocked: dedupBlocked,
        auditEscalationLevel: toolBudget.auditCount,
        quality: quality.name,
        resultPreview: chatService._toolSecretPolicy.previewText(
          chatService._prettyJsonString(result),
          maxChars: 600,
        ),
      ),
    );
    return quality;
  }
}

/// 在预算、审批或执行前完成可见性与计划步骤门禁。
final class _ToolCallPreflight {
  const _ToolCallPreflight({required this.chatService, required this.recorder});

  final LlmChatService chatService;
  final _ToolResultRecorder recorder;

  _ToolPreflightDisposition evaluate({
    required StreamingToolCall call,
    required AiTool? tool,
    required Map<String, dynamic> arguments,
    required Object? redactedArguments,
    required String signature,
    required bool planMode,
    required PlanExecutionSnapshot? planSnapshot,
    required LlmProviderAdapter provider,
    required List<Map<String, dynamic>> workingMessages,
    required AppLanguage language,
    required void Function(LlmTraceEvent event)? onTrace,
  }) {
    if (tool == null) {
      final result = jsonEncode({
        'error': 'Tool is not available in the current context.',
        'tool': call.name,
      });
      onTrace?.call(
        LlmTraceEvent(
          kind: 'tool_blocked',
          title: 'Tool blocked: ${call.name} (not visible)',
          content: 'Tool "${call.name}" is not exposed in the current context.',
        ),
      );
      recorder.record(
        call: call,
        provider: provider,
        workingMessages: workingMessages,
        signature: signature,
        redactedArguments: redactedArguments,
        result: result,
        outcome: 'tool_not_visible',
        language: language,
        onTrace: onTrace,
        index: recorder.toolBudget.usedCalls,
        qualityOverride: ToolResultQuality.unsafeBlocked,
        includeHint: false,
        failedOverride: true,
      );
      workingMessages.add({
        'role': 'system',
        'content':
            'The requested tool is not available in the current context. Do not call hidden or unavailable tools. Use only the tools currently exposed to you, or ask the user to select the required server/session/mode first.',
      });
      return _ToolPreflightDisposition.blocked;
    }
    if (planMode || planSnapshot == null || planSnapshot.steps.isEmpty) {
      return _ToolPreflightDisposition.proceed;
    }
    final gate = const PlanExecutionController().canRunToolForCurrentStep(
      steps: planSnapshot.steps,
      toolName: tool.name,
      arguments: arguments,
    );
    if (gate.allowed) return _ToolPreflightDisposition.proceed;

    final error = <String, dynamic>{
      'error': 'Tool call blocked by plan execution gate.',
    };
    if (gate.reason == 'task_update_required') {
      error
        ..['code'] = 'task_update_required'
        ..['taskId'] = gate.currentStep?.id
        ..['nextAction'] =
            'Call client_task_update with status=running for the current task before executing this tool.';
    } else if (gate.reason == 'previous_step_failed') {
      error
        ..['code'] = 'plan_execution_blocked'
        ..['reason'] = 'A preceding step has failed.'
        ..['nextAction'] =
            'Stop execution and ask the user whether to retry, skip, or revise the plan.';
    } else {
      error
        ..['code'] = 'plan_execution_blocked'
        ..['reason'] = gate.reason;
    }
    if (gate.currentStep != null) {
      error['currentStep'] = {
        'taskId': gate.currentStep!.id,
        'name': gate.currentStep!.name,
        'status': gate.currentStep!.status.name,
      };
    }
    final result = jsonEncode(error);
    onTrace?.call(
      LlmTraceEvent(
        kind: 'tool_blocked',
        title: 'Tool blocked by plan execution gate: ${call.name}',
        content: chatService._prettyJson({
          'tool': call.name,
          'executionMode': tool.executionMode.name,
          'stepScoped': true,
          'reason': gate.reason,
          'currentStepId': gate.currentStep?.id,
          'currentStepStatus': gate.currentStep?.status.name,
        }),
      ),
    );
    recorder.record(
      call: call,
      provider: provider,
      workingMessages: workingMessages,
      signature: signature,
      redactedArguments: redactedArguments,
      result: result,
      outcome: 'plan_execution_blocked',
      language: language,
      onTrace: onTrace,
      index: recorder.toolBudget.usedCalls,
      failedOverride: true,
    );
    return _ToolPreflightDisposition.planBlocked;
  }
}

/// 独占工具预算审计、人工扩展确认和剩余调用封禁写回。
final class _ToolBudgetAuditCoordinator {
  const _ToolBudgetAuditCoordinator({
    required this.chatService,
    required this.toolBudget,
    required this.toolLedger,
  });

  final LlmChatService chatService;
  final LlmToolBudgetController toolBudget;
  final List<LlmToolLedgerEntry> toolLedger;

  Future<bool> authorizeNext({
    required List<StreamingToolCall> toolCalls,
    required int toolIndex,
    required StreamingToolCall call,
    required LlmProviderAdapter provider,
    required List<Map<String, dynamic>> workingMessages,
    required Future<AiToolApprovalDecision> Function(
      AiToolApprovalRequest request,
    )?
    requestToolApproval,
    required void Function(LlmTraceEvent event)? onTrace,
    required LlmCancellationToken? cancellationToken,
    required AiConnectionSettings settings,
    required String apiKey,
    required String auditModel,
    required String originalUserGoal,
  }) async {
    final check = toolBudget.checkBeforeToolCall();
    if (check.requiresAudit) {
      var humanApproved = true;
      if (toolBudget.auditCount >= 3) {
        if (requestToolApproval == null) {
          humanApproved = false;
        } else {
          chatService._emitBudgetTrace(
            onTrace,
            title: 'Requesting human approval for safety audit extension',
            content: chatService._prettyJson({
              'message':
                  'AI tool usage requires additional human confirmation after 3 automated safety audits.',
              'budget': toolBudget.toJson(),
              'auditCount': toolBudget.auditCount,
              'nextTool': call.name,
            }),
          );
          final decision = await requestToolApproval(
            const AiToolApprovalRequest(
              toolName: 'budget_audit',
              approvalType: 'budget_audit',
              connectionId: 'local',
              connectionName: 'System',
              command: 'Request permission to extend tool usage budget',
              reason:
                  'The assistant has performed 3 automated safety audits. Continue using tools?',
            ),
          );
          humanApproved = decision.approved;
        }
      }
      if (!humanApproved) {
        final blocked = LlmToolSafetyAuditResult.blocked(
          summary: 'The user rejected the request to continue tool usage.',
          issues: const <String>['Human safety approval was denied.'],
          suspectedLoop: false,
          goalDrift: false,
          recommendedNextAction: 'Finish the conversation without more tools.',
        );
        chatService._emitBudgetTrace(
          onTrace,
          title: 'Tool budget safety audit rejected by user',
          content: chatService._prettyJson({
            'message': 'The user rejected the request to continue tool usage.',
            'budget': toolBudget.toJson(),
            'auditCount': toolBudget.auditCount,
          }),
        );
        _appendBlockedRemainder(
          toolCalls: toolCalls,
          toolIndex: toolIndex,
          auditResult: blocked,
          provider: provider,
          workingMessages: workingMessages,
          onTrace: onTrace,
        );
        return false;
      }

      toolBudget.recordAuditTriggered();
      chatService._emitBudgetTrace(
        onTrace,
        title: 'Tool budget safety audit running',
        content: chatService._prettyJson({
          'message':
              'Tool usage reached the current ceiling. Running an internal safety audit before granting more tool calls.',
          'budget': toolBudget.toJson(),
          'nextTool': call.name,
        }),
      );
      final audit = await chatService._runToolSafetyAudit(
        baseUrl: settings.baseUrl,
        apiKey: apiKey,
        model: auditModel,
        deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
        deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
        openAiReasoningEffort: settings.openAiReasoningEffort,
        originalUserGoal: originalUserGoal,
        workingMessages: workingMessages,
        toolLedger: toolLedger,
        toolBudget: toolBudget,
        cancellationToken: cancellationToken,
      );
      cancellationToken?.throwIfCancelled();
      if (!audit.shouldContinue) {
        chatService._emitBudgetTrace(
          onTrace,
          title: 'Tool budget safety audit rejected',
          content: chatService._prettyJson({
            'message':
                'The safety audit rejected further tool use for this run. Tools are now disabled and the assistant must finish without more tool calls.',
            'budget': toolBudget.toJson(),
            'summary': audit.summary,
            'issues': audit.issues,
            'suspectedLoop': audit.suspectedLoop,
            'goalDrift': audit.goalDrift,
            'recommendedNextAction': audit.recommendedNextAction,
          }),
        );
        _appendBlockedRemainder(
          toolCalls: toolCalls,
          toolIndex: toolIndex,
          auditResult: audit,
          provider: provider,
          workingMessages: workingMessages,
          onTrace: onTrace,
        );
        return false;
      }
      final extension = toolBudget.approveAuditExtension();
      chatService._emitBudgetTrace(
        onTrace,
        title: 'Tool budget safety audit approved',
        content: chatService._prettyJson({
          'message':
              'The safety audit approved continued tool use. The tool budget was extended again.',
          'budget': toolBudget.toJson(),
          'extension': extension.toJson(),
          'summary': audit.summary,
          'issues': audit.issues,
          'suspectedLoop': audit.suspectedLoop,
          'goalDrift': audit.goalDrift,
          'recommendedNextAction': audit.recommendedNextAction,
        }),
      );
    }

    final extension = toolBudget.recordAcceptedToolCall();
    if (extension != null) {
      chatService._emitBudgetTrace(
        onTrace,
        title: 'Tool budget reached and auto-extended',
        content: chatService._prettyJson({
          'message':
              'The default tool budget was reached. The app automatically granted more tool calls. Please review whether the assistant is still using tools reasonably.',
          'budget': toolBudget.toJson(),
          'extension': extension.toJson(),
        }),
      );
    }
    return true;
  }

  void _appendBlockedRemainder({
    required List<StreamingToolCall> toolCalls,
    required int toolIndex,
    required LlmToolSafetyAuditResult auditResult,
    required LlmProviderAdapter provider,
    required List<Map<String, dynamic>> workingMessages,
    required void Function(LlmTraceEvent event)? onTrace,
  }) {
    for (var index = toolIndex; index < toolCalls.length; index++) {
      final blockedCall = toolCalls[index];
      final result = chatService._toolBudgetBlockedToolResult(
        toolName: blockedCall.name,
        toolBudget: toolBudget,
        auditResult: auditResult,
      );
      chatService._emitToolResultTrace(
        onTrace,
        blockedCall.name,
        result,
        outcome: 'budget_audit_rejected',
      );
      workingMessages.add(
        provider.buildToolResultMessage(
          call: LlmProviderToolCall(
            id: blockedCall.id,
            name: blockedCall.name,
            argumentsJson: blockedCall.arguments,
          ),
          result: result,
        ),
      );
    }
    workingMessages.add({
      'role': 'system',
      'content': chatService._toolBudgetRejectedFollowUpPrompt(
        auditResult: auditResult,
        toolBudget: toolBudget,
      ),
    });
  }
}

extension ToolLoopControllerHelpers on ToolLoopController {
  Future<ToolLoopResult?> _tryHandleParallelReadOnlyToolCalls({
    required List<StreamingToolCall> toolCalls,
    required Map<String, AiTool> visibleToolsByName,
    required AppLanguage language,
    required List<Map<String, dynamic>> workingMessages,
    required LlmProviderAdapter activeProvider,
    required void Function(LlmTraceEvent event)? onTrace,
    required LlmCancellationToken? cancellationToken,
  }) async {
    if (toolCalls.length < 2) return null;
    final recorder = _ToolResultRecorder(
      chatService: chatService,
      toolBudget: toolBudget,
      toolLedger: toolLedger,
    );

    final prepared = <_ParallelReadOnlyCall>[];
    final seenSignatures = <String>{};
    for (final call in toolCalls) {
      final tool = visibleToolsByName[call.name];
      if (tool == null ||
          tool.executionMode != AiToolExecutionMode.readOnly ||
          !tool.parallelSafeReadOnly ||
          tool.needsServerSelection ||
          tool.needsWebViewSession) {
        return null;
      }

      final arguments = chatService._decodeArguments(call.arguments);
      final approvalRequest = await chatService.toolService.approvalRequestFor(
        call.name,
        arguments,
      );
      if (approvalRequest != null) return null;

      final redactedArguments = chatService._toolSecretPolicy.redactValue(
        arguments,
      );
      final signatureArguments = chatService._mapFromValue(redactedArguments);
      final signature = LlmToolLedgerEntry.buildSignature(
        call.name,
        signatureArguments,
      );
      if (!seenSignatures.add(signature)) return null;
      if (chatService._nextRepeatedSignatureStreak(toolLedger, signature) >=
              3 ||
          chatService._wouldTriggerAlternatingLoop(toolLedger, signature)) {
        return null;
      }

      prepared.add(
        _ParallelReadOnlyCall(
          call: call,
          tool: tool,
          arguments: arguments,
          redactedArguments: redactedArguments,
          signature: signature,
        ),
      );
    }

    if (!toolBudget.canAcceptCallsWithoutAudit(prepared.length)) {
      return null;
    }

    onTrace?.call(
      LlmTraceEvent(
        kind: 'tool_parallel_batch',
        title: 'Parallel read-only tool batch',
        content: chatService._prettyJson({
          'tools': prepared.map((item) => item.call.name).toList(),
          'count': prepared.length,
          'policy':
              'read-only, no approval, explicit parallel-safe flag, unique signatures',
        }),
      ),
    );

    final pendingResults = <Future<_ParallelReadOnlyResult>>[];
    final immediateResults = <_ParallelReadOnlyResult>[];
    for (final item in prepared) {
      cancellationToken?.throwIfCancelled();
      onTrace?.call(
        LlmTraceEvent(
          kind: 'tool_request',
          title: 'Tool request: ${item.call.name}',
          content: chatService._prettyJson({
            'tool': item.call.name,
            'arguments': item.redactedArguments,
            'parallelBatch': true,
          }),
        ),
      );

      final budgetEvent = toolBudget.recordAcceptedToolCall();
      if (budgetEvent != null) {
        chatService._emitBudgetTrace(
          onTrace,
          title: 'Tool budget reached and auto-extended',
          content: chatService._prettyJson({
            'message':
                'The default tool budget was reached. The app automatically granted more tool calls. Please review whether the assistant is still using tools reasonably.',
            'budget': toolBudget.toJson(),
            'extension': budgetEvent.toJson(),
          }),
        );
      }

      final cacheEntry = readOnlyToolCache[item.signature];
      if (item.tool.effectiveCacheTtl > Duration.zero &&
          cacheEntry != null &&
          !cacheEntry.isExpired) {
        cacheHitCount += 1;
        immediateResults.add(
          _ParallelReadOnlyResult(
            item: item,
            index: toolBudget.usedCalls,
            result: cacheEntry.result,
            outcome: 'cache_hit',
            cacheHit: true,
          ),
        );
        continue;
      }

      final index = toolBudget.usedCalls;
      pendingResults.add(
        (() async {
          try {
            final result = await chatService.toolService.execute(
              item.call.name,
              item.arguments,
              approvedWrite: false,
            );
            return _ParallelReadOnlyResult(
              item: item,
              index: index,
              result: result,
              outcome: chatService._classifyToolResultOutcome(result),
            );
          } on LlmCancelledException {
            rethrow;
          } catch (e) {
            _currentOutcome = AgentFinalOutcome.toolError;
            return _ParallelReadOnlyResult(
              item: item,
              index: index,
              result: jsonEncode({
                'error': chatService._toolSecretPolicy.redactText(e.toString()),
              }),
              outcome: 'execution_error',
            );
          }
        })(),
      );
    }

    final completed =
        [...immediateResults, ...await Future.wait(pendingResults)]..sort(
          (a, b) =>
              prepared.indexOf(a.item).compareTo(prepared.indexOf(b.item)),
        );

    for (final completedResult in completed) {
      cancellationToken?.throwIfCancelled();
      final item = completedResult.item;
      final result = completedResult.result;
      final outcome = completedResult.outcome;
      final cacheHit = completedResult.cacheHit;

      recorder.record(
        call: item.call,
        provider: activeProvider,
        workingMessages: workingMessages,
        signature: item.signature,
        redactedArguments: item.redactedArguments,
        result: result,
        outcome: outcome,
        language: language,
        onTrace: onTrace,
        index: completedResult.index,
        cacheHit: cacheHit,
      );

      if (!cacheHit &&
          item.tool.executionMode == AiToolExecutionMode.readOnly &&
          item.tool.effectiveCacheTtl > Duration.zero) {
        readOnlyToolCache[item.signature] = CachedToolResult(
          result: result,
          expiresAt: DateTime.now().add(item.tool.effectiveCacheTtl),
        );
      }
    }

    return ToolLoopResult(
      toolsShouldBeDisabled: _toolsDisabled,
      finalOutcome: _currentOutcome,
    );
  }

  PlanExecutionSnapshot? _snapshotAfterClientTaskTool({
    required PlanExecutionSnapshot? current,
    required String toolName,
    required Map<String, dynamic> arguments,
    required String resultJson,
    required String outcome,
  }) {
    if (current == null || current.steps.isEmpty || outcome != 'success') {
      return current;
    }
    if (toolName != 'client_task_update' &&
        toolName != 'client_task_retry' &&
        toolName != 'client_task_skip') {
      return current;
    }

    final taskId = arguments['taskId'];
    if (taskId is! String || taskId.trim().isEmpty) return current;
    final index = current.steps.indexWhere((step) => step.id == taskId);
    if (index == -1) return current;

    StepStatus? nextStatus;
    if (toolName == 'client_task_retry') {
      nextStatus = StepStatus.pending;
    } else if (toolName == 'client_task_skip') {
      nextStatus = StepStatus.skipped;
    } else {
      nextStatus =
          _statusFromTaskToolResult(resultJson) ??
          _statusFromRaw(arguments['status']);
    }
    if (nextStatus == null) return current;

    final steps = [...current.steps];
    final previous = steps[index];
    final stdout = arguments['stdout'] is String
        ? (arguments['stdout'] as String)
        : previous.stdout;
    final stderr = arguments['stderr'] is String
        ? (arguments['stderr'] as String)
        : previous.stderr;
    final exitCode = switch (nextStatus) {
      StepStatus.success => 0,
      StepStatus.failed => 1,
      StepStatus.pending => null,
      StepStatus.skipped => null,
      StepStatus.running => previous.exitCode,
    };

    steps[index] = AiTodoStep(
      id: previous.id,
      name: previous.name,
      command: previous.command,
      description: previous.description,
      status: nextStatus,
      stdout: nextStatus == StepStatus.pending ? null : stdout,
      stderr: nextStatus == StepStatus.pending ? null : stderr,
      exitCode: exitCode,
      connectionId: previous.connectionId,
    );
    return const PlanExecutionController().snapshot(steps);
  }

  StepStatus? _statusFromTaskToolResult(String resultJson) {
    try {
      final decoded = jsonDecode(resultJson);
      if (decoded is Map) {
        return _statusFromRaw(decoded['newStatus']);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  StepStatus? _statusFromRaw(Object? raw) {
    if (raw is! String) return null;
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'in_progress') return StepStatus.running;
    for (final value in StepStatus.values) {
      if (value.name == normalized) return value;
    }
    return null;
  }

  Future<void> _triggerPostToolReview({
    required AgentFinalOutcome finalOutcome,
    required String originalUserGoal,
    required List<Map<String, dynamic>> workingMessages,
    required AppLanguage language,
    required MultiAgentCompletion complete,
    required MultiAgentClassificationCompletion classify,
    required void Function(LlmTraceEvent event)? onTrace,
    required LlmCancellationToken? cancellationToken,
    required AiConnectionSettings settings,
    PlanExecutionSnapshot? planExecutionSnapshot,
  }) async {
    final needsPostReview =
        (finalOutcome == AgentFinalOutcome.toolError ||
        finalOutcome == AgentFinalOutcome.loopGuardBlocked ||
        finalOutcome == AgentFinalOutcome.approvalRejected ||
        finalOutcome == AgentFinalOutcome.budgetAuditRejected ||
        finalOutcome == AgentFinalOutcome.approvalUnavailable);

    if (!needsPostReview) return;

    if (!settings.postToolReviewEnabled) {
      onTrace?.call(
        LlmTraceEvent(
          kind: 'multi_agent_post_tool_review_skipped',
          title: 'Post-tool review skipped',
          content: 'skipped_by_setting: postToolReviewEnabled=false',
        ),
      );
      return;
    }

    final currentTodoStep = planExecutionSnapshot?.currentStep;
    final recentLedger = toolLedger.isNotEmpty ? toolLedger.last : null;

    final String recentStepText;
    if (currentTodoStep != null) {
      recentStepText = [
        'Current Plan Step:',
        '- taskId: ${currentTodoStep.id}',
        '- name: ${currentTodoStep.name}',
        '- command: ${chatService._toolSecretPolicy.previewText(currentTodoStep.command, maxChars: 300)}',
        '- status: ${currentTodoStep.status.name}',
        if (currentTodoStep.connectionId?.trim().isNotEmpty == true)
          '- connectionId: ${currentTodoStep.connectionId}',
      ].join('\n');
    } else {
      recentStepText = 'No active plan step.';
    }

    final planPhaseText = planExecutionSnapshot == null
        ? 'No active plan snapshot.'
        : 'Plan execution phase: ${planExecutionSnapshot.phase.name}';

    final postToolContext = [
      'Goal: $originalUserGoal',
      planPhaseText,
      recentStepText,
      if (recentLedger != null) ...[
        'Last tool called: ${recentLedger.toolName}',
        'Arguments preview: ${recentLedger.argumentsPreview}',
        'Outcome: ${recentLedger.outcome}',
        'Result preview: ${recentLedger.resultPreview}',
      ],
    ].join('\n');

    final trigger = switch (finalOutcome) {
      AgentFinalOutcome.loopGuardBlocked => MultiAgentTrigger.postLoopGuard,
      AgentFinalOutcome.approvalRejected =>
        MultiAgentTrigger.postApprovalRejection,
      AgentFinalOutcome.budgetAuditRejected =>
        MultiAgentTrigger.postBudgetAudit,
      AgentFinalOutcome.approvalUnavailable =>
        MultiAgentTrigger.postToolFailure,
      _ => MultiAgentTrigger.postToolFailure,
    };

    chatService._emitPostToolReviewTrace(onTrace, trigger, postToolContext);

    final reviewResult = await chatService.multiAgentCoordinator.run(
      messages: workingMessages,
      enabled: settings.postToolReviewEnabled,
      maxAgents: settings.multiAgentMaxAgents,
      trigger: trigger,
      postToolContext: postToolContext,
      checkCancelled: cancellationToken?.throwIfCancelled,
      language: language,
      complete: complete,
      classify: classify,
    );

    if (reviewResult != null) {
      workingMessages.add({
        'role': 'system',
        'content': reviewResult.memoryContent,
      });
      onTrace?.call(
        LlmTraceEvent(
          kind: 'multi_agent_post_tool_review',
          title: 'Multi-agent post-tool review',
          content: reviewResult.traceContent,
        ),
      );
    }
  }
}
