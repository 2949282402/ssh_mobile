part of '../llm_chat_service.dart';

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

      chatService._emitToolResultTrace(
        onTrace,
        item.call.name,
        result,
        outcome: outcome,
        cacheHit: cacheHit,
        dedupBlocked: false,
      );
      workingMessages.add(
        activeProvider.buildToolResultMessage(
          call: LlmProviderToolCall(
            id: item.call.id,
            name: item.call.name,
            argumentsJson: item.call.arguments,
          ),
          result: result,
        ),
      );

      final quality = ToolResultClassifier.classify(
        toolName: item.call.name,
        resultJson: result,
        outcome: outcome,
        approvalRequired: false,
        approved: false,
        cacheHit: cacheHit,
        dedupBlocked: false,
      );
      final hint = ToolResultClassifier.getSystemHint(
        item.call.name,
        quality,
        language,
      );
      if (hint != null) {
        workingMessages.add({'role': 'system', 'content': hint});
      }

      toolLedger.add(
        LlmToolLedgerEntry(
          index: completedResult.index,
          toolName: item.call.name,
          signature: item.signature,
          argumentsPreview: chatService._toolSecretPolicy.previewText(
            chatService._prettyJson(item.redactedArguments),
            maxChars: 400,
          ),
          outcome: outcome,
          approvalRequired: false,
          approved: false,
          failed: outcome != 'success' && outcome != 'cache_hit',
          emptyResult: chatService._looksLikeEmptyToolResult(result),
          cacheHit: cacheHit,
          dedupBlocked: false,
          auditEscalationLevel: toolBudget.auditCount,
          quality: quality.name,
          resultPreview: chatService._toolSecretPolicy.previewText(
            chatService._prettyJsonString(result),
            maxChars: 600,
          ),
        ),
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
