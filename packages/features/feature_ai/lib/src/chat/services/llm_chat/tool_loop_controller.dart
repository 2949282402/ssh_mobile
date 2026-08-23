part of '../llm_chat_service.dart';

class ToolLoopResult {
  final bool shouldStop;
  final String? stopMessage;
  final bool toolsShouldBeDisabled;
  final AgentFinalOutcome? finalOutcome;
  final PlanExecutionSnapshot? planExecutionSnapshot;

  const ToolLoopResult({
    this.shouldStop = false,
    this.stopMessage,
    this.toolsShouldBeDisabled = false,
    this.finalOutcome,
    this.planExecutionSnapshot,
  });
}

class ToolLoopController {
  final LlmChatService chatService;
  final LlmToolBudgetController toolBudget;
  final Map<String, CachedToolResult> readOnlyToolCache;
  final List<LlmToolLedgerEntry> toolLedger;
  final LlmProviderAdapter? provider;

  int cacheHitCount = 0;
  int dedupBlockedCount = 0;
  int approvalCount = 0;
  int approvedCount = 0;

  bool _toolsDisabled = false;
  AgentFinalOutcome? _currentOutcome;

  ToolLoopController({
    required this.chatService,
    required this.toolBudget,
    required this.readOnlyToolCache,
    required this.toolLedger,
    this.provider,
  });

  Future<ToolLoopResult> handleToolCalls({
    required List<StreamingToolCall> toolCalls,
    required Map<String, AiTool> visibleToolsByName,
    required bool planMode,
    required AppLanguage language,
    required String apiKey,
    required String auditModel,
    required String originalUserGoal,
    required List<Map<String, dynamic>> workingMessages,
    required Future<AiToolApprovalDecision> Function(
      AiToolApprovalRequest request,
    )?
    requestToolApproval,
    required void Function(LlmTraceEvent event)? onTrace,
    required LlmCancellationToken? cancellationToken,
    required AiConnectionSettings settings,
    required MultiAgentCompletion complete,
    required MultiAgentClassificationCompletion classify,
    PlanExecutionSnapshot? planExecutionSnapshot,
  }) async {
    final activeProvider =
        provider ?? LlmProviderFactory.fromSettings(settings);
    final resultRecorder = _ToolResultRecorder(
      chatService: chatService,
      toolBudget: toolBudget,
      toolLedger: toolLedger,
    );
    final preflight = _ToolCallPreflight(
      chatService: chatService,
      recorder: resultRecorder,
    );
    final budgetAuditor = _ToolBudgetAuditCoordinator(
      chatService: chatService,
      toolBudget: toolBudget,
      toolLedger: toolLedger,
    );
    final parallelResult = await _tryHandleParallelReadOnlyToolCalls(
      toolCalls: toolCalls,
      visibleToolsByName: visibleToolsByName,
      language: language,
      workingMessages: workingMessages,
      activeProvider: activeProvider,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
    );
    if (parallelResult != null) {
      return parallelResult;
    }
    PlanExecutionSnapshot? activeSnapshot = planExecutionSnapshot;
    for (var toolIndex = 0; toolIndex < toolCalls.length; toolIndex++) {
      final call = toolCalls[toolIndex];
      cancellationToken?.throwIfCancelled();

      var result = jsonEncode({'error': 'Tool execution did not complete.'});
      var outcome = 'success';
      var approvalRequired = false;
      var approvedWrite = false;
      var stopAfterToolResult = false;
      var cacheHit = false;
      var dedupBlocked = false;
      String? stopMessage;

      final arguments = chatService._decodeArguments(call.arguments);
      onTrace?.call(
        LlmTraceEvent(
          kind: 'tool_request',
          title: 'Tool request: ${call.name}',
          content: chatService._prettyJson({
            'tool': call.name,
            'arguments': chatService._toolSecretPolicy.redactValue(arguments),
          }),
        ),
      );

      final tool = visibleToolsByName[call.name];
      final redactedArguments = chatService._toolSecretPolicy.redactValue(
        arguments,
      );
      final signatureArguments = chatService._mapFromValue(redactedArguments);
      final signature = LlmToolLedgerEntry.buildSignature(
        call.name,
        signatureArguments,
      );

      final preflightDisposition = preflight.evaluate(
        call: call,
        tool: tool,
        arguments: arguments,
        redactedArguments: redactedArguments,
        signature: signature,
        planMode: planMode,
        planSnapshot: activeSnapshot,
        provider: activeProvider,
        workingMessages: workingMessages,
        language: language,
        onTrace: onTrace,
      );
      if (preflightDisposition != _ToolPreflightDisposition.proceed) {
        if (preflightDisposition == _ToolPreflightDisposition.planBlocked) {
          _currentOutcome = AgentFinalOutcome.planExecutionBlocked;
        }
        continue;
      }
      if (tool == null) continue;

      final budgetAuthorized = await budgetAuditor.authorizeNext(
        toolCalls: toolCalls,
        toolIndex: toolIndex,
        call: call,
        provider: activeProvider,
        workingMessages: workingMessages,
        requestToolApproval: requestToolApproval,
        onTrace: onTrace,
        cancellationToken: cancellationToken,
        settings: settings,
        apiKey: apiKey,
        auditModel: auditModel,
        originalUserGoal: originalUserGoal,
      );
      if (!budgetAuthorized) {
        _toolsDisabled = true;
        _currentOutcome = AgentFinalOutcome.budgetAuditRejected;
        await _triggerPostToolReview(
          finalOutcome: AgentFinalOutcome.budgetAuditRejected,
          originalUserGoal: originalUserGoal,
          workingMessages: workingMessages,
          language: language,
          complete: complete,
          classify: classify,
          onTrace: onTrace,
          cancellationToken: cancellationToken,
          settings: settings,
          planExecutionSnapshot: activeSnapshot,
        );
        return ToolLoopResult(
          toolsShouldBeDisabled: true,
          finalOutcome: AgentFinalOutcome.budgetAuditRejected,
          planExecutionSnapshot: activeSnapshot,
        );
      }

      result = jsonEncode({'error': 'Tool execution did not complete.'});
      outcome = 'success';
      approvalRequired = false;
      approvedWrite = false;
      stopAfterToolResult = false;
      cacheHit = false;
      dedupBlocked = false;
      stopMessage = null;

      try {
        final repeatedStreak = chatService._nextRepeatedSignatureStreak(
          toolLedger,
          signature,
        );

        if (tool.executionMode == AiToolExecutionMode.readOnly &&
            (repeatedStreak >= 3 ||
                chatService._wouldTriggerAlternatingLoop(
                  toolLedger,
                  signature,
                ))) {
          dedupBlocked = true;
          dedupBlockedCount += 1;
          outcome = 'loop_guard_blocked';
          result = jsonEncode({
            'error':
                'Deterministic loop guard blocked a repeated read-only tool cycle. Summarize the current findings or choose a different next step.',
            'tool': call.name,
          });
          _toolsDisabled = true;
          _currentOutcome = AgentFinalOutcome.loopGuardBlocked;
          workingMessages.add({
            'role': 'system',
            'content':
                'The deterministic loop guard blocked repeated tool usage. Stop calling the same read-only tools and finish with the best available answer unless the user gives new instructions.',
          });
        }

        final cacheEntry = readOnlyToolCache[signature];
        if (!dedupBlocked &&
            tool.executionMode == AiToolExecutionMode.readOnly &&
            tool.effectiveCacheTtl > Duration.zero &&
            cacheEntry != null &&
            !cacheEntry.isExpired) {
          cacheHit = true;
          cacheHitCount += 1;
          outcome = 'cache_hit';
          result = cacheEntry.result;
        }

        final approvalRequest = await chatService.toolService
            .approvalRequestFor(call.name, arguments);
        approvalRequired = approvalRequest != null;
        final approvalTargetGuard =
            chatService.toolService is AiToolApprovalTargetGuard
            ? chatService.toolService as AiToolApprovalTargetGuard
            : null;
        AiToolApprovalRequest? approvedRequest;

        if (!dedupBlocked && !cacheHit && approvalRequest != null) {
          approvalCount += 1;
          onTrace?.call(
            LlmTraceEvent(
              kind: 'approval',
              title: 'Tool action approval requested',
              content: chatService._prettyJson({
                'tool': call.name,
                'status': 'requested',
                'approvalType': approvalRequest.approvalType,
                'server': approvalRequest.connectionName,
                'command': approvalRequest.command,
                'reason': approvalRequest.reason,
              }),
            ),
          );
          if (planMode) {
            outcome = 'blocked_in_plan_mode';
            _currentOutcome = AgentFinalOutcome.planModeBlocked;
            result = jsonEncode({
              'error':
                  'This write operation or state-changing action is blocked because PLAN MODE is active. You must only outline your plan without execution.',
              'command': approvalRequest.command,
            });
            onTrace?.call(
              LlmTraceEvent(
                kind: 'approval',
                title: 'Action blocked in Plan Mode',
                content: chatService._prettyJson({
                  'tool': call.name,
                  'status': 'blocked_in_plan_mode',
                  'message': 'Action blocked in plan mode',
                  'command': approvalRequest.command,
                }),
              ),
            );
          } else if (requestToolApproval == null) {
            outcome = 'approval_unavailable';
            _currentOutcome = AgentFinalOutcome.approvalUnavailable;
            result = jsonEncode({
              'error':
                  'This tool action requires user approval, but no approval UI is available.',
              'command': approvalRequest.command,
            });
            stopAfterToolResult = true;
            stopMessage =
                '\n\nTool action requires approval, but approval is unavailable. Operation stopped.';
          } else {
            AppLogService.instance.info(
              'AI tool approval requested',
              details:
                  'tool=${call.name} connection=${approvalRequest.connectionName} command=${approvalRequest.command}',
            );
            final decision = await requestToolApproval(approvalRequest);
            cancellationToken?.throwIfCancelled();

            if (!decision.approved) {
              outcome = 'approval_rejected';
              AppLogService.instance.warning(
                'AI tool approval rejected',
                details:
                    'tool=${call.name} connection=${approvalRequest.connectionName} abort=${decision.abort}',
              );
              result = jsonEncode({
                'error': 'User rejected the requested tool action.',
                'command': approvalRequest.command,
                if (decision.feedback?.trim().isNotEmpty == true)
                  'feedback': decision.feedback!.trim(),
              });
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'approval',
                  title: 'Tool action rejected',
                  content: chatService._prettyJson({
                    'tool': call.name,
                    'status': 'rejected',
                    'approvalType': approvalRequest.approvalType,
                    'server': approvalRequest.connectionName,
                    'command': approvalRequest.command,
                    'abort': decision.abort,
                    if (decision.feedback?.trim().isNotEmpty == true)
                      'feedback': decision.feedback!.trim(),
                  }),
                ),
              );
              stopAfterToolResult = decision.abort;
              if (decision.abort) {
                stopMessage =
                    '\n\nTool action rejected. Operation stopped. You can tell me what to do next.';
                _currentOutcome = AgentFinalOutcome.approvalRejected;
              }
            } else if (approvalTargetGuard != null &&
                !await approvalTargetGuard.isApprovalTargetCurrent(
                  approvalRequest,
                )) {
              outcome = 'approval_target_changed';
              result = jsonEncode({
                'error':
                    'The server connection changed after approval was requested. Review the current target and approve the action again.',
                'code': 'approval_target_changed',
                'command': approvalRequest.command,
              });
              stopAfterToolResult = true;
              stopMessage =
                  '\n\nServer connection changed while approval was open. No action was executed; review the target and approve again.';
              _currentOutcome = AgentFinalOutcome.approvalRejected;
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'approval',
                  title: 'Tool approval target changed',
                  content: chatService._prettyJson({
                    'tool': call.name,
                    'status': 'target_changed',
                    'approvalType': approvalRequest.approvalType,
                    'server': approvalRequest.connectionName,
                    'command': approvalRequest.command,
                  }),
                ),
              );
              AppLogService.instance.warning(
                'AI tool approval target changed',
                details:
                    'tool=${call.name} connection=${approvalRequest.connectionName}',
              );
            } else {
              approvedWrite = true;
              approvedRequest = approvalRequest;
              approvedCount += 1;
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'approval',
                  title: 'Tool action approved',
                  content: chatService._prettyJson({
                    'tool': call.name,
                    'status': 'approved',
                    'approvalType': approvalRequest.approvalType,
                    'server': approvalRequest.connectionName,
                    'command': approvalRequest.command,
                  }),
                ),
              );
              AppLogService.instance.info(
                'AI tool approval accepted',
                details:
                    'tool=${call.name} connection=${approvalRequest.connectionName} command=${approvalRequest.command}',
              );
            }
          }
        }

        if (!dedupBlocked &&
            !cacheHit &&
            (approvedWrite || !approvalRequired)) {
          if (!planMode &&
              activeSnapshot != null &&
              activeSnapshot.steps.isNotEmpty) {
            final currentStep = activeSnapshot.currentStep;
            if (currentStep != null) {
              final stepIndex = activeSnapshot.steps.indexWhere(
                (s) => s.id == currentStep.id,
              );
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'plan_step_tool_binding',
                  title:
                      'Step-Tool Binding: ${currentStep.name} -> ${call.name}',
                  content: chatService._prettyJson({
                    'taskId': currentStep.id,
                    'stepIndex': stepIndex,
                    'stepName': currentStep.name,
                    'toolName': call.name,
                    'connectionId': currentStep.connectionId,
                    'commandPreview': chatService._toolSecretPolicy.previewText(
                      currentStep.command,
                      maxChars: 300,
                    ),
                    'statusBefore': currentStep.status.name,
                  }),
                ),
              );
            }
          }

          result =
              approvedWrite &&
                  approvedRequest != null &&
                  approvalTargetGuard != null
              ? await approvalTargetGuard.executeApproved(
                  approvedRequest,
                  arguments,
                )
              : await chatService.toolService.execute(
                  call.name,
                  arguments,
                  approvedWrite: approvedWrite,
                );
          cancellationToken?.throwIfCancelled();
          outcome = chatService._classifyToolResultOutcome(result);
          if (!planMode) {
            activeSnapshot = _snapshotAfterClientTaskTool(
              current: activeSnapshot,
              toolName: call.name,
              arguments: arguments,
              resultJson: result,
              outcome: outcome,
            );
          }

          if (!planMode &&
              activeSnapshot != null &&
              activeSnapshot.steps.isNotEmpty) {
            final currentStep = activeSnapshot.currentStep;
            if (currentStep != null) {
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'plan_step_tool_binding',
                  title:
                      'Step-Tool Outcome: ${currentStep.name} -> ${call.name}',
                  content: chatService._prettyJson({
                    'taskId': currentStep.id,
                    'toolName': call.name,
                    'toolOutcome': outcome,
                    'resultPreview': chatService._toolSecretPolicy.previewText(
                      result,
                      maxChars: 300,
                    ),
                    'suggestedTaskStatus': outcome == 'success'
                        ? 'success'
                        : 'failed',
                  }),
                ),
              );
            }
          }

          if (tool.executionMode == AiToolExecutionMode.readOnly &&
              tool.effectiveCacheTtl > Duration.zero) {
            readOnlyToolCache[signature] = CachedToolResult(
              result: result,
              expiresAt: DateTime.now().add(tool.effectiveCacheTtl),
            );
          }
        }
      } on LlmCancelledException {
        rethrow;
      } catch (e) {
        outcome = 'execution_error';
        _currentOutcome = AgentFinalOutcome.toolError;
        result = jsonEncode({
          'error': chatService._toolSecretPolicy.redactText(e.toString()),
        });
      }

      resultRecorder.record(
        call: call,
        provider: activeProvider,
        workingMessages: workingMessages,
        signature: signature,
        redactedArguments: redactedArguments,
        result: result,
        outcome: outcome,
        language: language,
        onTrace: onTrace,
        index: toolBudget.usedCalls,
        approvalRequired: approvalRequired,
        approved: approvedWrite,
        cacheHit: cacheHit,
        dedupBlocked: dedupBlocked,
        failedOverride: outcome != 'success',
      );

      if (stopAfterToolResult) {
        final finalOutcome = _currentOutcome ?? AgentFinalOutcome.success;
        await _triggerPostToolReview(
          finalOutcome: finalOutcome,
          originalUserGoal: originalUserGoal,
          workingMessages: workingMessages,
          language: language,
          complete: complete,
          classify: classify,
          onTrace: onTrace,
          cancellationToken: cancellationToken,
          settings: settings,
          planExecutionSnapshot: activeSnapshot,
        );
        return ToolLoopResult(
          shouldStop: true,
          stopMessage: stopMessage,
          toolsShouldBeDisabled: _toolsDisabled,
          finalOutcome: finalOutcome,
          planExecutionSnapshot: activeSnapshot,
        );
      }
    }

    final finalOutcome = _currentOutcome ?? AgentFinalOutcome.success;
    await _triggerPostToolReview(
      finalOutcome: finalOutcome,
      originalUserGoal: originalUserGoal,
      workingMessages: workingMessages,
      language: language,
      complete: complete,
      classify: classify,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
      settings: settings,
      planExecutionSnapshot: activeSnapshot,
    );

    return ToolLoopResult(
      shouldStop: false,
      toolsShouldBeDisabled: _toolsDisabled,
      finalOutcome: finalOutcome,
      planExecutionSnapshot: activeSnapshot,
    );
  }
}

class _ParallelReadOnlyCall {
  final StreamingToolCall call;
  final AiTool tool;
  final Map<String, dynamic> arguments;
  final Object? redactedArguments;
  final String signature;

  const _ParallelReadOnlyCall({
    required this.call,
    required this.tool,
    required this.arguments,
    required this.redactedArguments,
    required this.signature,
  });
}

class _ParallelReadOnlyResult {
  final _ParallelReadOnlyCall item;
  final int index;
  final String result;
  final String outcome;
  final bool cacheHit;

  const _ParallelReadOnlyResult({
    required this.item,
    required this.index,
    required this.result,
    required this.outcome,
    this.cacheHit = false,
  });
}
