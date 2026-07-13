part of '../llm_chat_service.dart';

extension LlmChatServiceStreamHandler on LlmChatService {
  Future<String> _sendImpl({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
    requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    String? runId,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool planMode = false,
    AiChatMessageRecord? approvedPlanMessage,
  }) async {
    final buffer = StringBuffer();
    await for (final chunk in _streamImpl(
      messages: messages,
      modelOverride: modelOverride,
      requestToolApproval: requestToolApproval,
      onStats: onStats,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
      runId: runId,
      userRequest: userRequest,
      selectedConnectionIds: selectedConnectionIds,
      hasWebViewSession: hasWebViewSession,
      hasApprovedPlan: hasApprovedPlan,
      memorySources: memorySources,
      planMode: planMode,
      approvedPlanMessage: approvedPlanMessage,
    )) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  Stream<String> _streamImpl({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
    requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    String? runId,
    Set<String>? allowedTools,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool forceContextCompression = false,
    bool planMode = false,
    AiChatMessageRecord? approvedPlanMessage,
  }) async* {
    final settings =
        _runtimeSettings ?? await storageService.loadAiConnectionSettings();
    final provider = LlmProviderFactory.fromSettings(settings);
    var planExecutionSnapshot = approvedPlanMessage == null
        ? null
        : const PlanExecutionController().snapshot(
            approvedPlanMessage.todoSteps,
          );
    final runStartedAt = DateTime.now();
    final resolvedRunId = runId?.trim().isNotEmpty == true
        ? runId!.trim()
        : const Uuid().v4();
    var finalOutcome = AgentFinalOutcome.success;
    final agentLoopGuard = AgentLoopGuard(mode: settings.agentLoopMode);
    final modelProfile = _modelProfileForSettings(
      settings,
      mainModelOverride: modelOverride,
    );
    final model = modelProfile.resolve(AgentModelRole.main);
    final helperModel = modelProfile.resolve(AgentModelRole.helper);
    final auditModel = modelProfile.resolve(AgentModelRole.audit);
    final apiKey = _runtimeApiKey ?? await storageService.getAiApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      AppLogService.instance.warning('LLM request blocked: API key missing');
      throw StateError('API key is not configured.');
    }
    _assertValidHeaderApiKey(apiKey);
    AppLogService.instance.info(
      'LLM chat started',
      details:
          'baseUrl=${settings.baseUrl} model=$model helperModel=$helperModel auditModel=$auditModel userMessages=${messages.length} forceContextCompression=$forceContextCompression planMode=$planMode',
    );
    onTrace?.call(
      LlmTraceEvent(
        kind: 'agent_run_started',
        title: 'Agent run started',
        content: _prettyJson({
          'runId': resolvedRunId,
          'model': model,
          'helperModel': helperModel,
          'auditModel': auditModel,
          'planMode': planMode,
          'selectedConnectionIdsCount': selectedConnectionIds.length,
          'hasWebViewSession': hasWebViewSession,
          'hasApprovedPlan': hasApprovedPlan,
          'messageCount': messages.length,
          'agentLoopMode': agentLoopGuard.mode,
          'modelRoundLimit': agentLoopGuard.modelRoundLimit,
          'startedAt': runStartedAt.toIso8601String(),
        }),
      ),
    );

    var workingMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPromptFor(planMode: planMode)},
      ...messages,
    ];
    final estimatedBeforeCompression = LlmChatService.estimateMessagesTokens(
      workingMessages,
    );
    var compressed = false;
    final shouldCompressFromUsageThreshold =
        estimatedBeforeCompression >= settings.contextWindowTokens * 0.9;

    final visibleOutput = StringBuffer();
    var selectedToolSet = <String>[];
    var toolLedger = <LlmToolLedgerEntry>[];
    ToolLoopController? toolLoopController;
    LlmToolBudgetController? toolBudget;
    MultiAgentRunResult? multiAgentResult;
    var summaryEmitted = false;

    try {
      if (shouldCompressFromUsageThreshold || forceContextCompression) {
        onTrace?.call(
          LlmTraceEvent(
            kind: 'context_compression_started',
            title: 'Context compression started',
            content: _prettyJson({
              'estimatedBeforeCompression': estimatedBeforeCompression,
              'contextWindowTokens': settings.contextWindowTokens,
              'forceContextCompression': forceContextCompression,
              'messageCountBefore': messages.length,
            }),
          ),
        );
        workingMessages = await _compressWorkingMessages(
          baseUrl: settings.baseUrl,
          apiKey: apiKey,
          model: model,
          messages: messages,
          contextWindowTokens: settings.contextWindowTokens,
          deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
          deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
          openAiReasoningEffort: settings.openAiReasoningEffort,
          cancellationToken: cancellationToken,
        );
        compressed = true;
        onTrace?.call(
          LlmTraceEvent(
            kind: 'context_compression_completed',
            title: 'Context compression completed',
            content: _prettyJson({
              'estimatedBeforeCompression': estimatedBeforeCompression,
              'contextWindowTokens': settings.contextWindowTokens,
              'forceContextCompression': forceContextCompression,
              'compressed': compressed,
              'messageCountBefore': messages.length,
              'messageCountAfter': workingMessages.length,
            }),
          ),
        );
        if (forceContextCompression && !shouldCompressFromUsageThreshold) {
          AppLogService.instance.info(
            'LLM context compression forced',
            details:
                'baseTokens=$estimatedBeforeCompression window=${settings.contextWindowTokens}',
          );
        }
      }
      final availableTools = await toolService.tools();
      final normalizedAllowedTools = _normalizeToolNames(allowedTools);

      final toolSelection = toolExposureRouter.selectTools(
        availableTools,
        context: ToolExposureContext(
          userRequest: userRequest,
          planMode: planMode,
          hasWebViewSession: hasWebViewSession,
          hasApprovedPlan: hasApprovedPlan,
          selectedConnectionIds: selectedConnectionIds,
          allowedTools: normalizedAllowedTools,
        ),
      );
      final visibleTools = toolSelection.tools;

      final hiddenTools = toolSelection.decisions
          .where((d) => !d.selected)
          .toList();
      final hiddenReasons = hiddenTools.expand((d) => d.blockedBy).toList();
      final topHiddenReasons = <String, int>{};
      for (final reason in hiddenReasons) {
        topHiddenReasons[reason] = (topHiddenReasons[reason] ?? 0) + 1;
      }

      onTrace?.call(
        LlmTraceEvent(
          kind: 'tool_exposure',
          title: 'Tool exposure selection',
          content: _prettyJson({
            'requestedCapabilities': toolSelection.requestedCapabilities
                .map((c) => c.name)
                .toList(),
            'selectedTools': visibleTools.map((t) => t.name).toList(),
            'hiddenToolsCount': hiddenTools.length,
            'topHiddenReasons': topHiddenReasons,
            'planMode': planMode,
            'hasApprovedPlan': hasApprovedPlan,
            'hasWebViewSession': hasWebViewSession,
            'selectedConnectionIdsCount': selectedConnectionIds.length,
          }),
        ),
      );

      selectedToolSet = visibleTools
          .map((tool) => tool.name)
          .toList(growable: false);
      final visibleToolsByName = {
        for (final tool in visibleTools) tool.name: tool,
      };
      var currentToolDefinitions = visibleTools
          .map((tool) => tool.definitionFor(settings))
          .toList(growable: false);
      final readOnlyToolCache = <String, CachedToolResult>{};
      toolBudget = LlmToolBudgetController(baseBudget: settings.toolCallBudget);
      toolLedger = <LlmToolLedgerEntry>[];
      toolLoopController = ToolLoopController(
        chatService: this,
        toolBudget: toolBudget,
        readOnlyToolCache: readOnlyToolCache,
        toolLedger: toolLedger,
        provider: provider,
      );
      final originalUserGoal = _latestUserGoal(messages);
      if (normalizedAllowedTools == null) {
        AppLogService.instance.info(
          'LLM tool filter skipped',
          details:
              'availableTools=${availableTools.length} filteredTools=${currentToolDefinitions.length} planMode=$planMode',
        );
      } else {
        AppLogService.instance.info(
          'LLM tool definitions filtered',
          details:
              'requestedTools=${normalizedAllowedTools.length} availableTools=${availableTools.length} filteredTools=${currentToolDefinitions.length} planMode=$planMode',
        );
      }

      final isMultiAgent = settings.multiAgentEnabled || planMode;
      final activeMaxAgents = planMode ? 5 : settings.multiAgentMaxAgents;

      multiAgentResult = await multiAgentCoordinator.run(
        messages: workingMessages,
        enabled: isMultiAgent,
        maxAgents: activeMaxAgents,
        checkCancelled: cancellationToken?.throwIfCancelled,
        language: language,
        plannerPrompt: plannerPrompt,
        operatorPrompt: operatorPrompt,
        explorePrompt: explorePrompt,
        reviewerPrompt: reviewerPrompt,
        summarizerPrompt: summarizerPrompt,
        coordinatorPrompt: coordinatorPrompt,
        planMode: planMode,
        classify: (classificationMessages) async {
          final response = await provider.complete(
            LlmProviderRequest(
              baseUrl: settings.baseUrl,
              apiKey: apiKey,
              model: helperModel,
              messages: classificationMessages,
              deepSeekThinkingEnabled: false,
              deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
              openAiReasoningEffort: 'low',
              cancellationToken: cancellationToken,
              timeoutSeconds: settings.timeoutSeconds,
            ),
          );
          return response.text;
        },
        complete: (role, roleMessages, {required thinkingSettings}) async {
          final response = await provider.complete(
            LlmProviderRequest(
              baseUrl: settings.baseUrl,
              apiKey: apiKey,
              model: helperModel,
              messages: roleMessages,
              deepSeekThinkingEnabled: thinkingSettings.thinkingEnabled,
              deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
              openAiReasoningEffort: thinkingSettings.reasoningEffort,
              cancellationToken: cancellationToken,
              timeoutSeconds: settings.timeoutSeconds,
            ),
          );
          return response.text;
        },
      );
      if (multiAgentResult != null) {
        workingMessages.add({
          'role': 'assistant',
          'content': multiAgentResult.memoryContent,
        });
        onTrace?.call(
          LlmTraceEvent(
            kind: 'multi_agent',
            title: 'Multi-agent collaboration',
            content: multiAgentResult.traceContent,
          ),
        );

        if (planMode) {
          final outcome = await _validateAndRepairPlanOutput(
            initialText: multiAgentResult.memoryContent,
            language: language,
            settings: settings,
            apiKey: apiKey,
            model: model,
            workingMessages: workingMessages,
            cancellationToken: cancellationToken,
            onTrace: onTrace,
            chatId: _resolveChatId(),
          );

          yield outcome.finalText;
          workingMessages.last['content'] = outcome.finalText;

          final elapsedMs = DateTime.now()
              .difference(runStartedAt)
              .inMilliseconds;
          final promptTokens = LlmChatService.estimateMessagesTokens(
            workingMessages,
          );
          final completionTokens = LlmChatService.estimateTextTokens(
            outcome.finalText,
          );
          onStats?.call(
            LlmRunStats(
              promptTokens: promptTokens,
              completionTokens: completionTokens,
              totalTokens: promptTokens + completionTokens,
              elapsedMs: elapsedMs,
              usageFromProvider: false,
              contextTokensBeforeCompression: estimatedBeforeCompression,
              contextWindowTokens: settings.contextWindowTokens,
              compressed: compressed,
              helperFanout: multiAgentResult.agentCount,
              selectedToolSet: selectedToolSet,
              memorySources: memorySources,
              agentLoopMode: agentLoopGuard.mode,
              modelRoundsUsed: agentLoopGuard.modelRoundsUsed,
              modelRoundLimit: agentLoopGuard.modelRoundLimit,
              loopExtensionCount: agentLoopGuard.loopExtensionCount,
              loopStopReason: agentLoopGuard.loopStopReason,
            ),
          );
          visibleOutput.write(outcome.finalText);
          return;
        }
      }

      while (true) {
        cancellationToken?.throwIfCancelled();
        if (agentLoopGuard.shouldRequestApproval(
          toolsEnabled: currentToolDefinitions.isNotEmpty,
        )) {
          final approved = await _requestAgentLoopRoundApproval(
            guard: agentLoopGuard,
            requestToolApproval: requestToolApproval,
            onTrace: onTrace,
          );
          if (!approved) {
            finalOutcome =
                agentLoopGuard.loopStopReason == 'approval_unavailable'
                ? AgentFinalOutcome.approvalUnavailable
                : AgentFinalOutcome.agentLoopStopped;
            currentToolDefinitions = const [];
            workingMessages.add({
              'role': 'system',
              'content': _agentLoopPausedInstruction(language),
            });
          }
        }
        agentLoopGuard.recordModelRoundStarted();
        final roundNumber = agentLoopGuard.modelRoundsUsed;
        final roundStartedAt = DateTime.now();
        onTrace?.call(
          LlmTraceEvent(
            kind: 'model_round_started',
            title: 'Model round $roundNumber started',
            content: _prettyJson({
              'round': roundNumber,
              'messageCount': workingMessages.length,
              'toolDefinitionsCount': currentToolDefinitions.length,
              'contentChars': visibleOutput.length,
              'agentLoop': agentLoopGuard.toJson(),
            }),
          ),
        );
        final content = StringBuffer();
        final chunkController = StreamController<String>();
        _StreamChatResult? streamedResponse;
        Object? streamedError;
        StackTrace? streamedStackTrace;

        Future<void> pumpStream() async {
          try {
            final result = await provider.streamChat(
              LlmProviderRequest(
                baseUrl: settings.baseUrl,
                apiKey: apiKey,
                model: model,
                messages: workingMessages,
                tools: currentToolDefinitions,
                deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
                deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
                openAiReasoningEffort: settings.openAiReasoningEffort,
                cancellationToken: cancellationToken,
                includeTools: currentToolDefinitions.isNotEmpty,
                onTextDelta: (chunk) {
                  cancellationToken?.throwIfCancelled();
                  content.write(chunk);
                  chunkController.add(chunk);
                },
                timeoutSeconds: settings.timeoutSeconds,
              ),
            );
            streamedResponse = _StreamChatResult(
              contentChunks: [result.text],
              reasoningContent: result.reasoningContent ?? '',
              toolCalls: result.toolCalls
                  .map(
                    (c) => StreamingToolCall(
                      id: c.id,
                      name: c.name,
                      arguments: c.argumentsJson,
                    ),
                  )
                  .toList(),
              usage: result.usage,
            );
          } catch (e, stackTrace) {
            streamedError = e;
            streamedStackTrace = stackTrace;
          } finally {
            await chunkController.close();
          }
        }

        unawaited(pumpStream());

        await for (final chunk in chunkController.stream) {
          if (planMode) {
            visibleOutput.write(chunk);
            continue;
          }
          visibleOutput.write(chunk);
          yield chunk;
        }
        if (streamedError != null) {
          Error.throwWithStackTrace(streamedError!, streamedStackTrace!);
        }
        cancellationToken?.throwIfCancelled();
        final response = streamedResponse;
        if (response == null) {
          throw StateError('LLM stream ended without a response.');
        }
        onTrace?.call(
          LlmTraceEvent(
            kind: 'model_round_completed',
            title: 'Model round $roundNumber completed',
            content: _prettyJson({
              'round': roundNumber,
              'messageCount': workingMessages.length,
              'toolDefinitionsCount': currentToolDefinitions.length,
              'contentChars': content.length,
              'toolCallCount': response.toolCalls.length,
              'agentLoop': agentLoopGuard.toJson(),
              'elapsedMs': DateTime.now()
                  .difference(roundStartedAt)
                  .inMilliseconds,
            }),
          ),
        );
        _emitReasoningTrace(onTrace, response.reasoningContent);

        if (response.toolCalls.isEmpty) {
          var answer = content.toString().trim().isNotEmpty
              ? content.toString()
              : 'Done.';

          if (planMode) {
            final outcome = await _validateAndRepairPlanOutput(
              initialText: answer,
              language: language,
              settings: settings,
              apiKey: apiKey,
              model: model,
              workingMessages: [
                ...workingMessages,
                {'role': 'assistant', 'content': answer},
              ],
              cancellationToken: cancellationToken,
              onTrace: onTrace,
              chatId: _resolveChatId(),
            );
            answer = outcome.finalText;
            yield answer;
            visibleOutput.clear();
            visibleOutput.write(answer);
          } else {
            if (content.isEmpty) yield answer;
          }
          AppLogService.instance.info(
            'LLM chat completed',
            details: 'rounds=$roundNumber answerChars=${answer.length}',
          );
          final elapsedMs = DateTime.now()
              .difference(runStartedAt)
              .inMilliseconds;
          final promptTokens =
              response.usage?.promptTokens ??
              LlmChatService.estimateMessagesTokens(workingMessages);
          final completionTokens =
              response.usage?.completionTokens ??
              LlmChatService.estimateTextTokens(answer);
          onStats?.call(
            LlmRunStats(
              promptTokens: promptTokens,
              completionTokens: completionTokens,
              totalTokens:
                  response.usage?.totalTokens ??
                  promptTokens + completionTokens,
              elapsedMs: elapsedMs,
              usageFromProvider: response.usage != null,
              promptCacheHitTokens: response.usage?.promptCacheHitTokens,
              promptCacheMissTokens: response.usage?.promptCacheMissTokens,
              reasoningTokens: response.usage?.reasoningTokens,
              contextTokensBeforeCompression: estimatedBeforeCompression,
              contextWindowTokens: settings.contextWindowTokens,
              compressed: compressed,
              toolCalls: toolLedger.length,
              cacheHits: toolLoopController.cacheHitCount,
              dedupBlockedCalls: toolLoopController.dedupBlockedCount,
              helperFanout: multiAgentResult?.agentCount ?? 0,
              auditEscalationLevel: toolBudget.auditCount,
              selectedToolSet: selectedToolSet,
              memorySources: memorySources,
              approvalCount: toolLoopController.approvalCount,
              approvedCount: toolLoopController.approvedCount,
              agentLoopMode: agentLoopGuard.mode,
              modelRoundsUsed: agentLoopGuard.modelRoundsUsed,
              modelRoundLimit: agentLoopGuard.modelRoundLimit,
              loopExtensionCount: agentLoopGuard.loopExtensionCount,
              loopStopReason: agentLoopGuard.loopStopReason,
            ),
          );
          return;
        }

        AppLogService.instance.info(
          'LLM requested tools',
          details:
              'round=$roundNumber tools=${response.toolCalls.map((call) => call.name).join(',')}',
        );
        final assistantToolMessage = provider.buildAssistantToolCallMessage(
          text: content.toString(),
          toolCalls: response.toolCalls
              .map(
                (c) => LlmProviderToolCall(
                  id: c.id,
                  name: c.name,
                  argumentsJson: c.arguments,
                ),
              )
              .toList(),
          reasoningContent: response.reasoningContent.trim().isNotEmpty
              ? response.reasoningContent
              : null,
        );
        workingMessages.add(assistantToolMessage);
        final toolLedgerStart = toolLedger.length;
        final loopResult = await toolLoopController.handleToolCalls(
          toolCalls: response.toolCalls,
          visibleToolsByName: visibleToolsByName,
          planMode: planMode,
          language: language,
          apiKey: apiKey,
          auditModel: auditModel,
          originalUserGoal: originalUserGoal,
          workingMessages: workingMessages,
          requestToolApproval: requestToolApproval,
          onTrace: onTrace,
          cancellationToken: cancellationToken,
          settings: settings,
          planExecutionSnapshot: planExecutionSnapshot,
          complete: (role, roleMessages, {required thinkingSettings}) async {
            final response = await provider.complete(
              LlmProviderRequest(
                baseUrl: settings.baseUrl,
                apiKey: apiKey,
                model: helperModel,
                messages: roleMessages,
                deepSeekThinkingEnabled: thinkingSettings.thinkingEnabled,
                deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
                openAiReasoningEffort: thinkingSettings.reasoningEffort,
                cancellationToken: cancellationToken,
                timeoutSeconds: settings.timeoutSeconds,
              ),
            );
            return response.text;
          },
          classify: (classificationMessages) async {
            final response = await provider.complete(
              LlmProviderRequest(
                baseUrl: settings.baseUrl,
                apiKey: apiKey,
                model: helperModel,
                messages: classificationMessages,
                deepSeekThinkingEnabled: false,
                deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
                openAiReasoningEffort: 'low',
                cancellationToken: cancellationToken,
                timeoutSeconds: settings.timeoutSeconds,
              ),
            );
            return response.text;
          },
        );
        planExecutionSnapshot =
            loopResult.planExecutionSnapshot ?? planExecutionSnapshot;
        agentLoopGuard.recordToolRound(
          contentChars: content.length,
          newEntries: toolLedger.sublist(toolLedgerStart),
        );

        finalOutcome = loopResult.finalOutcome ?? AgentFinalOutcome.success;

        if (loopResult.toolsShouldBeDisabled) {
          currentToolDefinitions = const [];
        }

        if (loopResult.shouldStop) {
          if (loopResult.stopMessage != null) {
            yield loopResult.stopMessage!;
          }
          return;
        }
        final separator = _toolContinuationSeparator(visibleOutput.toString());
        if (separator.isNotEmpty) {
          visibleOutput.write(separator);
          yield separator;
        }
      }
    } on LlmCancelledException {
      finalOutcome = AgentFinalOutcome.cancelled;
      rethrow;
    } catch (e) {
      if (finalOutcome == AgentFinalOutcome.success) {
        finalOutcome = AgentFinalOutcome.modelError;
      }
      rethrow;
    } finally {
      if (!summaryEmitted) {
        summaryEmitted = true;
        final finishedAt = DateTime.now();
        final summary = AgentRunSummary(
          runId: resolvedRunId,
          startedAt: runStartedAt,
          finishedAt: finishedAt,
          model: model,
          helperModel: helperModel,
          auditModel: auditModel,
          planMode: planMode,
          promptTokens: LlmChatService.estimateMessagesTokens(workingMessages),
          completionTokens: LlmChatService.estimateTextTokens(
            visibleOutput.toString(),
          ),
          toolCalls: toolLedger.length,
          cacheHits: toolLoopController?.cacheHitCount ?? 0,
          dedupBlockedCalls: toolLoopController?.dedupBlockedCount ?? 0,
          approvalCount: toolLoopController?.approvalCount ?? 0,
          approvedCount: toolLoopController?.approvedCount ?? 0,
          helperFanout: multiAgentResult?.agentCount ?? 0,
          auditEscalationLevel: toolBudget?.auditCount ?? 0,
          selectedToolSet: selectedToolSet,
          memorySources: memorySources,
          finalOutcome: finalOutcome,
          agentLoopMode: agentLoopGuard.mode,
          modelRoundsUsed: agentLoopGuard.modelRoundsUsed,
          modelRoundLimit: agentLoopGuard.modelRoundLimit,
          loopExtensionCount: agentLoopGuard.loopExtensionCount,
          loopStopReason: agentLoopGuard.loopStopReason,
        );

        onTrace?.call(
          LlmTraceEvent(
            kind: 'agent_run_summary',
            title: 'Agent run summary',
            content: _prettyJson(summary.toJson()),
          ),
        );
      }
    }
  }

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

class _PlanValidationOutcome {
  final String finalText;
  final PlanOutputValidationResult validation;
  final bool repaired;
  final bool repairFailed;

  const _PlanValidationOutcome({
    required this.finalText,
    required this.validation,
    required this.repaired,
    required this.repairFailed,
  });
}
