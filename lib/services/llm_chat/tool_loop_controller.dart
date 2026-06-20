part of '../llm_chat_service.dart';

class ToolLoopResult {
  final bool shouldStop;
  final String? stopMessage;
  final bool toolsShouldBeDisabled;
  final AgentFinalOutcome? finalOutcome;

  const ToolLoopResult({
    this.shouldStop = false,
    this.stopMessage,
    this.toolsShouldBeDisabled = false,
    this.finalOutcome,
  });
}

class ToolLoopController {
  final LlmChatService chatService;
  final LlmToolBudgetController toolBudget;
  final Map<String, CachedToolResult> readOnlyToolCache;
  final List<LlmToolLedgerEntry> toolLedger;

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
            AiToolApprovalRequest request)?
        requestToolApproval,
    required void Function(LlmTraceEvent event)? onTrace,
    required LlmCancellationToken? cancellationToken,
    required AiConnectionSettings settings,
    required MultiAgentCompletion complete,
    required MultiAgentClassificationCompletion classify,
    PlanExecutionSnapshot? planExecutionSnapshot,
  }) async {
    for (var toolIndex = 0; toolIndex < toolCalls.length; toolIndex++) {
      final call = toolCalls[toolIndex];
      cancellationToken?.throwIfCancelled();

      PlanExecutionSnapshot? activeSnapshot = planExecutionSnapshot;
      if (!planMode) {
        final ts = chatService.toolService;
        if (ts is AiToolService && ts.clientWebViewSessionId != null) {
          final chatId = ts.clientWebViewSessionId!;
          final chats = await chatService.storageService.loadAiChats();
          final chatIndex = chats.indexWhere((c) => c.id == chatId);
          if (chatIndex != -1) {
            final chat = chats[chatIndex];
            final approvedPlanRef = chat.approvedPlan;
            if (approvedPlanRef != null) {
              final planMsg = chatAssistantMessageByCreatedAt(
                chat,
                approvedPlanRef.assistantCreatedAt,
              );
              if (planMsg != null) {
                activeSnapshot =
                    const PlanExecutionController().snapshot(planMsg.todoSteps);
              }
            }
          }
        }
      }

      var result = jsonEncode({
        'error': 'Tool execution did not complete.',
      });
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
      final redactedArguments =
          chatService._toolSecretPolicy.redactValue(arguments);
      final signatureArguments = chatService._mapFromValue(redactedArguments);
      final signature = LlmToolLedgerEntry.buildSignature(
        call.name,
        signatureArguments,
      );

      if (tool == null) {
        outcome = 'tool_not_visible';
        result = jsonEncode({
          'error': 'Tool is not available in the current context.',
          'tool': call.name,
        });
        onTrace?.call(
          LlmTraceEvent(
            kind: 'tool_blocked',
            title: 'Tool blocked: ${call.name} (not visible)',
            content:
                'Tool "${call.name}" is not exposed in the current context.',
          ),
        );
        workingMessages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': result,
        });
        workingMessages.add({
          'role': 'system',
          'content':
              'The requested tool is not available in the current context. Do not call hidden or unavailable tools. Use only the tools currently exposed to you, or ask the user to select the required server/session/mode first.',
        });

        toolLedger.add(
          LlmToolLedgerEntry(
            index: toolBudget.usedCalls,
            toolName: call.name,
            signature: signature,
            argumentsPreview: chatService._toolSecretPolicy.previewText(
              chatService._prettyJson(redactedArguments),
              maxChars: 400,
            ),
            outcome: outcome,
            approvalRequired: false,
            approved: false,
            failed: true,
            emptyResult: false,
            cacheHit: false,
            dedupBlocked: false,
            auditEscalationLevel: toolBudget.auditCount,
            quality: ToolResultQuality.unsafeBlocked.name,
            resultPreview: chatService._toolSecretPolicy.previewText(
              chatService._prettyJsonString(result),
              maxChars: 600,
            ),
          ),
        );

        continue;
      }

      if (!planMode &&
          activeSnapshot != null &&
          activeSnapshot.steps.isNotEmpty) {
        final gateResult =
            const PlanExecutionController().canRunToolForCurrentStep(
          steps: activeSnapshot.steps,
          toolName: tool.name,
          arguments: arguments,
        );

        if (!gateResult.allowed) {
          outcome = 'plan_execution_blocked';
          _currentOutcome = AgentFinalOutcome.planExecutionBlocked;

          final Map<String, dynamic> errorObj = {
            'error': 'Tool call blocked by plan execution gate.',
          };
          if (gateResult.reason == 'task_update_required') {
            errorObj['code'] = 'task_update_required';
            errorObj['taskId'] = gateResult.currentStep?.id;
            errorObj['nextAction'] =
                'Call client_task_update with status=running for the current task before executing this tool.';
          } else if (gateResult.reason == 'previous_step_failed') {
            errorObj['code'] = 'plan_execution_blocked';
            errorObj['reason'] = 'A preceding step has failed.';
            errorObj['nextAction'] =
                'Stop execution and ask the user whether to retry, skip, or revise the plan.';
          } else {
            errorObj['code'] = 'plan_execution_blocked';
            errorObj['reason'] = gateResult.reason;
          }
          if (gateResult.currentStep != null) {
            errorObj['currentStep'] = {
              'taskId': gateResult.currentStep!.id,
              'name': gateResult.currentStep!.name,
              'status': gateResult.currentStep!.status.name,
            };
          }
          result = jsonEncode(errorObj);

          onTrace?.call(
            LlmTraceEvent(
              kind: 'tool_blocked',
              title: 'Tool blocked by plan execution gate: ${call.name}',
              content: chatService._prettyJson({
                'tool': call.name,
                'reason': gateResult.reason,
                'currentStepId': gateResult.currentStep?.id,
              }),
            ),
          );

          workingMessages.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'content': result,
          });

          final quality = ToolResultClassifier.classify(
            toolName: call.name,
            resultJson: result,
            outcome: outcome,
            approvalRequired: false,
            approved: false,
            cacheHit: false,
            dedupBlocked: false,
          );

          final hint =
              ToolResultClassifier.getSystemHint(call.name, quality, language);
          if (hint != null) {
            workingMessages.add({
              'role': 'system',
              'content': hint,
            });
          }

          toolLedger.add(
            LlmToolLedgerEntry(
              index: toolBudget.usedCalls,
              toolName: call.name,
              signature: signature,
              argumentsPreview: chatService._toolSecretPolicy.previewText(
                chatService._prettyJson(redactedArguments),
                maxChars: 400,
              ),
              outcome: outcome,
              approvalRequired: false,
              approved: false,
              failed: true,
              emptyResult: false,
              cacheHit: false,
              dedupBlocked: false,
              auditEscalationLevel: toolBudget.auditCount,
              quality: quality.name,
              resultPreview: chatService._toolSecretPolicy.previewText(
                chatService._prettyJsonString(result),
                maxChars: 600,
              ),
            ),
          );

          continue;
        }
      }

      final budgetCheck = toolBudget.checkBeforeToolCall();
      if (budgetCheck.requiresAudit) {
        bool humanApproved = true;
        if (toolBudget.auditCount >= 3) {
          if (requestToolApproval != null) {
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

            final humanDecision = await requestToolApproval(
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
            humanApproved = humanDecision.approved;
          } else {
            humanApproved = false;
          }
        }

        if (!humanApproved) {
          _toolsDisabled = true;
          final auditResult = LlmToolSafetyAuditResult.blocked(
            summary: 'The user rejected the request to continue tool usage.',
            issues: ['Human safety approval was denied.'],
            suspectedLoop: false,
            goalDrift: false,
            recommendedNextAction:
                'Finish the conversation without more tools.',
          );
          chatService._emitBudgetTrace(
            onTrace,
            title: 'Tool budget safety audit rejected by user',
            content: chatService._prettyJson({
              'message':
                  'The user rejected the request to continue tool usage.',
              'budget': toolBudget.toJson(),
              'auditCount': toolBudget.auditCount,
            }),
          );

          for (var blockedIndex = toolIndex;
              blockedIndex < toolCalls.length;
              blockedIndex++) {
            final blockedCall = toolCalls[blockedIndex];
            final blockedResult = chatService._toolBudgetBlockedToolResult(
              toolName: blockedCall.name,
              toolBudget: toolBudget,
              auditResult: auditResult,
            );
            chatService._emitToolResultTrace(
                onTrace, blockedCall.name, blockedResult);
            workingMessages.add({
              'role': 'tool',
              'tool_call_id': blockedCall.id,
              'content': blockedResult,
            });
          }

          workingMessages.add({
            'role': 'system',
            'content': chatService._toolBudgetRejectedFollowUpPrompt(
              auditResult: auditResult,
              toolBudget: toolBudget,
            ),
          });
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
          return const ToolLoopResult(
            toolsShouldBeDisabled: true,
            finalOutcome: AgentFinalOutcome.budgetAuditRejected,
          );
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

        final auditResult = await chatService._runToolSafetyAudit(
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

        if (auditResult.shouldContinue) {
          final budgetEvent = toolBudget.approveAuditExtension();
          chatService._emitBudgetTrace(
            onTrace,
            title: 'Tool budget safety audit approved',
            content: chatService._prettyJson({
              'message':
                  'The safety audit approved continued tool use. The tool budget was extended again.',
              'budget': toolBudget.toJson(),
              'extension': budgetEvent.toJson(),
              'summary': auditResult.summary,
              'issues': auditResult.issues,
              'suspectedLoop': auditResult.suspectedLoop,
              'goalDrift': auditResult.goalDrift,
              'recommendedNextAction': auditResult.recommendedNextAction,
            }),
          );
        } else {
          _toolsDisabled = true;
          chatService._emitBudgetTrace(
            onTrace,
            title: 'Tool budget safety audit rejected',
            content: chatService._prettyJson({
              'message':
                  'The safety audit rejected further tool use for this run. Tools are now disabled and the assistant must finish without more tool calls.',
              'budget': toolBudget.toJson(),
              'summary': auditResult.summary,
              'issues': auditResult.issues,
              'suspectedLoop': auditResult.suspectedLoop,
              'goalDrift': auditResult.goalDrift,
              'recommendedNextAction': auditResult.recommendedNextAction,
            }),
          );

          for (var blockedIndex = toolIndex;
              blockedIndex < toolCalls.length;
              blockedIndex++) {
            final blockedCall = toolCalls[blockedIndex];
            final blockedResult = chatService._toolBudgetBlockedToolResult(
              toolName: blockedCall.name,
              toolBudget: toolBudget,
              auditResult: auditResult,
            );
            chatService._emitToolResultTrace(
                onTrace, blockedCall.name, blockedResult);
            workingMessages.add({
              'role': 'tool',
              'tool_call_id': blockedCall.id,
              'content': blockedResult,
            });
          }

          workingMessages.add({
            'role': 'system',
            'content': chatService._toolBudgetRejectedFollowUpPrompt(
              auditResult: auditResult,
              toolBudget: toolBudget,
            ),
          });
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
          return const ToolLoopResult(
            toolsShouldBeDisabled: true,
            finalOutcome: AgentFinalOutcome.budgetAuditRejected,
          );
        }
      }

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

      result = jsonEncode({
        'error': 'Tool execution did not complete.',
      });
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
                    toolLedger, signature))) {
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

        final approvalRequest =
            await chatService.toolService.approvalRequestFor(
          call.name,
          arguments,
        );
        approvalRequired = approvalRequest != null;

        if (!dedupBlocked && !cacheHit && approvalRequest != null) {
          approvalCount += 1;
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
            } else {
              approvedWrite = true;
              approvedCount += 1;
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'approval',
                  title: 'Tool action approved',
                  content: chatService._prettyJson({
                    'tool': call.name,
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
              final stepIndex = activeSnapshot.steps
                  .indexWhere((s) => s.id == currentStep.id);
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
                    'commandPreview': chatService._toolSecretPolicy
                        .previewText(currentStep.command, maxChars: 300),
                    'statusBefore': currentStep.status.name,
                  }),
                ),
              );
            }
          }

          result = await chatService.toolService.execute(
            call.name,
            arguments,
            approvedWrite: approvedWrite,
          );
          cancellationToken?.throwIfCancelled();
          outcome = chatService._classifyToolResultOutcome(result);

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
                    'resultPreview': chatService._toolSecretPolicy
                        .previewText(result, maxChars: 300),
                    'suggestedTaskStatus':
                        outcome == 'success' ? 'success' : 'failed',
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

      chatService._emitToolResultTrace(onTrace, call.name, result);
      workingMessages.add({
        'role': 'tool',
        'tool_call_id': call.id,
        'content': result,
      });

      final quality = ToolResultClassifier.classify(
        toolName: call.name,
        resultJson: result,
        outcome: outcome,
        approvalRequired: approvalRequired,
        approved: approvedWrite,
        cacheHit: cacheHit,
        dedupBlocked: dedupBlocked,
      );

      final hint =
          ToolResultClassifier.getSystemHint(call.name, quality, language);
      if (hint != null) {
        workingMessages.add({
          'role': 'system',
          'content': hint,
        });
      }

      toolLedger.add(
        LlmToolLedgerEntry(
          index: toolBudget.usedCalls,
          toolName: call.name,
          signature: signature,
          argumentsPreview: chatService._toolSecretPolicy.previewText(
            chatService._prettyJson(redactedArguments),
            maxChars: 400,
          ),
          outcome: outcome,
          approvalRequired: approvalRequired,
          approved: approvedWrite,
          failed: outcome != 'success',
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
      planExecutionSnapshot: planExecutionSnapshot,
    );

    return ToolLoopResult(
      shouldStop: false,
      toolsShouldBeDisabled: _toolsDisabled,
      finalOutcome: finalOutcome,
    );
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
    final needsPostReview = (finalOutcome == AgentFinalOutcome.toolError ||
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
        '- command: ${currentTodoStep.command}',
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
