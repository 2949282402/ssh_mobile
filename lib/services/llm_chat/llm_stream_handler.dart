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
    final settings = await storageService.loadAiConnectionSettings();
    final planExecutionSnapshot = approvedPlanMessage == null
        ? null
        : const PlanExecutionController()
            .snapshot(approvedPlanMessage.todoSteps);
    final runStartedAt = DateTime.now();
    final resolvedRunId =
        runId?.trim().isNotEmpty == true ? runId!.trim() : const Uuid().v4();
    var finalOutcome = AgentFinalOutcome.success;
    final modelProfile = _modelProfileForSettings(
      settings,
      mainModelOverride: modelOverride,
    );
    final model = modelProfile.resolve(AgentModelRole.main);
    final helperModel = modelProfile.resolve(AgentModelRole.helper);
    final auditModel = modelProfile.resolve(AgentModelRole.audit);
    final apiKey = await storageService.getAiApiKey();
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
          'startedAt': runStartedAt.toIso8601String(),
        }),
      ),
    );

    var workingMessages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': systemPromptFor(planMode: planMode),
      },
      ...messages,
    ];
    final estimatedBeforeCompression =
        LlmChatService.estimateMessagesTokens(workingMessages);
    var compressed = false;
    final shouldCompressFromUsageThreshold =
        estimatedBeforeCompression >= settings.contextWindowTokens * 0.9;
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

    final hiddenTools =
        toolSelection.decisions.where((d) => !d.selected).toList();
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
          'requestedCapabilities':
              toolSelection.requestedCapabilities.map((c) => c.name).toList(),
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

    final selectedToolSet =
        visibleTools.map((tool) => tool.name).toList(growable: false);
    final visibleToolsByName = {
      for (final tool in visibleTools) tool.name: tool,
    };
    var currentToolDefinitions =
        visibleTools.map((tool) => tool.definition).toList(growable: false);
    final readOnlyToolCache = <String, CachedToolResult>{};
    final toolBudget = LlmToolBudgetController(
      baseBudget: settings.toolCallBudget,
    );
    final toolLedger = <LlmToolLedgerEntry>[];
    final toolLoopController = ToolLoopController(
      chatService: this,
      toolBudget: toolBudget,
      readOnlyToolCache: readOnlyToolCache,
      toolLedger: toolLedger,
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

    final multiAgentResult = await multiAgentCoordinator.run(
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
        final response = await _chatCompletion(
          baseUrl: settings.baseUrl,
          apiKey: apiKey,
          model: helperModel,
          messages: classificationMessages,
          deepSeekThinkingEnabled: false,
          deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
          openAiReasoningEffort: 'low',
          cancellationToken: cancellationToken,
          operationLabel: 'LLM multi-agent classification',
        );
        return _contentFromChatResponse(response);
      },
      complete: (role, roleMessages, {required thinkingSettings}) async {
        final response = await _chatCompletion(
          baseUrl: settings.baseUrl,
          apiKey: apiKey,
          model: helperModel,
          messages: roleMessages,
          deepSeekThinkingEnabled: thinkingSettings.thinkingEnabled,
          deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
          openAiReasoningEffort: thinkingSettings.reasoningEffort,
          cancellationToken: cancellationToken,
          operationLabel: 'LLM multi-agent helper (${role.name})',
        );
        return _contentFromChatResponse(response);
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

        final elapsedMs =
            DateTime.now().difference(runStartedAt).inMilliseconds;
        final promptTokens =
            LlmChatService.estimateMessagesTokens(workingMessages);
        final completionTokens =
            LlmChatService.estimateTextTokens(outcome.finalText);
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
          ),
        );
        final finishedAt = DateTime.now();
        onTrace?.call(
          LlmTraceEvent(
            kind: 'agent_run_summary',
            title: 'Agent run summary',
            content: _prettyJson(AgentRunSummary(
              runId: resolvedRunId,
              startedAt: runStartedAt,
              finishedAt: finishedAt,
              model: model,
              helperModel: helperModel,
              auditModel: auditModel,
              planMode: planMode,
              promptTokens: promptTokens,
              completionTokens: completionTokens,
              toolCalls: toolLedger.length,
              cacheHits: toolLoopController.cacheHitCount,
              dedupBlockedCalls: toolLoopController.dedupBlockedCount,
              approvalCount: toolLoopController.approvalCount,
              approvedCount: toolLoopController.approvedCount,
              helperFanout: multiAgentResult.agentCount,
              auditEscalationLevel: toolBudget.auditCount,
              selectedToolSet: selectedToolSet,
              memorySources: memorySources,
              finalOutcome: AgentFinalOutcome.success,
            ).toJson()),
          ),
        );
        return;
      }
    }

    final visibleOutput = StringBuffer();
    try {
      for (var round = 0;; round++) {
        cancellationToken?.throwIfCancelled();
        final roundStartedAt = DateTime.now();
        onTrace?.call(
          LlmTraceEvent(
            kind: 'model_round_started',
            title: 'Model round ${round + 1} started',
            content: _prettyJson({
              'round': round + 1,
              'messageCount': workingMessages.length,
              'toolDefinitionsCount': currentToolDefinitions.length,
              'contentChars': visibleOutput.length,
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
            streamedResponse = await _streamChatCompletion(
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
              onContent: (chunk) {
                cancellationToken?.throwIfCancelled();
                content.write(chunk);
                chunkController.add(chunk);
              },
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
            title: 'Model round ${round + 1} completed',
            content: _prettyJson({
              'round': round + 1,
              'messageCount': workingMessages.length,
              'toolDefinitionsCount': currentToolDefinitions.length,
              'contentChars': content.length,
              'toolCallCount': response.toolCalls.length,
              'elapsedMs':
                  DateTime.now().difference(roundStartedAt).inMilliseconds,
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
            details: 'rounds=${round + 1} answerChars=${answer.length}',
          );
          final elapsedMs =
              DateTime.now().difference(runStartedAt).inMilliseconds;
          final promptTokens = response.usage?.promptTokens ??
              LlmChatService.estimateMessagesTokens(workingMessages);
          final completionTokens = response.usage?.completionTokens ??
              LlmChatService.estimateTextTokens(answer);
          onStats?.call(
            LlmRunStats(
              promptTokens: promptTokens,
              completionTokens: completionTokens,
              totalTokens: response.usage?.totalTokens ??
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
            ),
          );
          return;
        }

        AppLogService.instance.info(
          'LLM requested tools',
          details:
              'round=${round + 1} tools=${response.toolCalls.map((call) => call.name).join(',')}',
        );
        final assistantToolMessage = <String, dynamic>{
          'role': 'assistant',
          'content': content.toString(),
          'tool_calls': [
            for (final call in response.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': call.arguments,
                },
              },
          ],
        };

        if (response.reasoningContent.trim().isNotEmpty) {
          assistantToolMessage['reasoning_content'] = response.reasoningContent;
        }
        workingMessages.add(assistantToolMessage);
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
            final response = await _chatCompletion(
              baseUrl: settings.baseUrl,
              apiKey: apiKey,
              model: helperModel,
              messages: roleMessages,
              deepSeekThinkingEnabled: thinkingSettings.thinkingEnabled,
              deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
              openAiReasoningEffort: thinkingSettings.reasoningEffort,
              cancellationToken: cancellationToken,
              operationLabel: 'LLM multi-agent helper (${role.name})',
            );
            return _contentFromChatResponse(response);
          },
          classify: (classificationMessages) async {
            final response = await _chatCompletion(
              baseUrl: settings.baseUrl,
              apiKey: apiKey,
              model: helperModel,
              messages: classificationMessages,
              deepSeekThinkingEnabled: false,
              deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
              openAiReasoningEffort: 'low',
              cancellationToken: cancellationToken,
              operationLabel: 'LLM multi-agent classification',
            );
            return _contentFromChatResponse(response);
          },
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
      finalOutcome = AgentFinalOutcome.modelError;
      rethrow;
    } finally {
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
        completionTokens:
            LlmChatService.estimateTextTokens(visibleOutput.toString()),
        toolCalls: toolLedger.length,
        cacheHits: toolLoopController.cacheHitCount,
        dedupBlockedCalls: toolLoopController.dedupBlockedCount,
        approvalCount: toolLoopController.approvalCount,
        approvedCount: toolLoopController.approvedCount,
        helperFanout: multiAgentResult?.agentCount ?? 0,
        auditEscalationLevel: toolBudget.auditCount,
        selectedToolSet: selectedToolSet,
        memorySources: memorySources,
        finalOutcome: finalOutcome,
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

  Future<_StreamChatResult> _streamChatCompletion({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
    required void Function(String chunk) onContent,
    LlmCancellationToken? cancellationToken,
    bool includeUsage = true,
    bool includeTools = true,
    bool includeReasoningParams = true,
  }) async {
    final endpoint = Uri.parse(_joinUrl(baseUrl, '/chat/completions'));
    for (var attempt = 0;
        attempt <= LlmChatService._networkRetryCount;
        attempt++) {
      final client = HttpClient();
      cancellationToken?.onCancel(() => client.close(force: true));
      final startedAt = DateTime.now();
      final contentChunks = <String>[];
      final reasoningContent = StringBuffer();
      final toolCalls = <int, StreamingToolCall>{};
      LlmTokenUsage? usage;
      AppLogService.instance.info(
        'LLM stream request sent',
        details:
            'endpoint=$endpoint model=$model messages=${messages.length} attempt=${attempt + 1}',
      );
      try {
        cancellationToken?.throwIfCancelled();
        final request = await client.postUrl(endpoint);
        cancellationToken?.throwIfCancelled();
        final useTools = includeTools && tools.isNotEmpty;
        final requestBody = <String, dynamic>{
          'model': model,
          'messages': messages,
          'stream': true,
          if (useTools) ...{
            'tools': tools,
            'tool_choice': 'auto',
          },
          if (includeUsage) 'stream_options': {'include_usage': true},
        };
        if (includeReasoningParams) {
          requestBody.addAll(
            _providerReasoningParams(
              baseUrl: baseUrl,
              model: model,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
            ),
          );
        }
        final bodyBytes = utf8.encode(jsonEncode(requestBody));
        request.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
          ..contentType = ContentType.json;
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.transform(utf8.decoder).join();
          if (includeUsage &&
              response.statusCode == 400 &&
              (body.contains('stream_options') ||
                  body.contains('include_usage'))) {
            AppLogService.instance.warning(
              'LLM stream usage unsupported, retrying without usage',
              details:
                  'endpoint=$endpoint model=$model bodyChars=${body.length}',
            );
            return _streamChatCompletion(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              messages: messages,
              tools: tools,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
              onContent: onContent,
              cancellationToken: cancellationToken,
              includeUsage: false,
              includeTools: includeTools,
              includeReasoningParams: includeReasoningParams,
            );
          }
          if (includeTools && _looksLikeToolUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM stream tools unsupported, retrying without tools',
              details:
                  'endpoint=$endpoint model=$model bodyChars=${body.length}',
            );
            return _streamChatCompletion(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              messages: messages,
              tools: tools,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
              onContent: onContent,
              cancellationToken: cancellationToken,
              includeUsage: includeUsage,
              includeTools: false,
              includeReasoningParams: includeReasoningParams,
            );
          }
          if (includeReasoningParams &&
              _looksLikeReasoningParamUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM reasoning params unsupported, retrying without them',
              details:
                  'endpoint=$endpoint model=$model bodyChars=${body.length}',
            );
            return _streamChatCompletion(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              messages: messages,
              tools: tools,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
              onContent: onContent,
              cancellationToken: cancellationToken,
              includeUsage: includeUsage,
              includeTools: includeTools,
              includeReasoningParams: false,
            );
          }
          AppLogService.instance.warning(
            'LLM stream request failed',
            details:
                'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
          );
          throw StateError(
            'LLM stream failed (${response.statusCode}): $body',
          );
        }

        await for (final line in response
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          cancellationToken?.throwIfCancelled();
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') break;
          if (data.isEmpty) continue;

          final decoded = jsonDecode(data) as Map<String, dynamic>;
          final rawUsage = decoded['usage'];
          if (rawUsage is Map<String, dynamic>) {
            usage = LlmTokenUsage.fromJson(rawUsage);
          }
          final choices = decoded['choices'] as List<dynamic>? ?? const [];
          if (choices.isEmpty) continue;
          final delta =
              (choices.first as Map<String, dynamic>)['delta'] as Map?;
          if (delta == null) continue;

          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            contentChunks.add(content);
            onContent(content);
          }

          final reasoning = delta['reasoning_content'];
          if (reasoning is String && reasoning.isNotEmpty) {
            reasoningContent.write(reasoning);
          }

          final rawToolCalls = delta['tool_calls'];
          if (rawToolCalls is List) {
            for (final rawCall in rawToolCalls) {
              if (rawCall is! Map) continue;
              final index = rawCall['index'] as int? ?? 0;
              final current = toolCalls.putIfAbsent(
                index,
                () => StreamingToolCall(id: '', name: '', arguments: ''),
              );
              final id = rawCall['id'];
              if (id is String && id.isNotEmpty) current.id = id;
              final function = rawCall['function'];
              if (function is Map) {
                final name = function['name'];
                if (name is String && name.isNotEmpty) current.name += name;
                final arguments = function['arguments'];
                if (arguments is String && arguments.isNotEmpty) {
                  current.arguments += arguments;
                }
              }
            }
          }
        }

        final calls = toolCalls.entries
            .where((entry) => entry.value.name.trim().isNotEmpty)
            .map((entry) {
          final call = entry.value;
          if (call.id.trim().isEmpty) {
            call.id = 'call_${entry.key}';
          }
          return call;
        }).toList();
        AppLogService.instance.info(
          'LLM stream response completed',
          details:
              'elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} chunks=${contentChunks.length} toolCalls=${calls.length} attempt=${attempt + 1}',
        );
        return _StreamChatResult(
          contentChunks: contentChunks,
          reasoningContent: reasoningContent.toString(),
          toolCalls: calls,
          usage: usage,
        );
      } catch (e, stackTrace) {
        if (cancellationToken?.isCancelled == true ||
            e is LlmCancelledException) {
          AppLogService.instance.info(
            'LLM stream cancelled',
            details: 'endpoint=$endpoint model=$model',
          );
          throw const LlmCancelledException();
        }
        final canRetry = _isRetryableNetworkError(e) &&
            contentChunks.isEmpty &&
            reasoningContent.isEmpty &&
            toolCalls.isEmpty &&
            attempt < LlmChatService._networkRetryCount;
        if (canRetry) {
          AppLogService.instance.warning(
            'LLM stream network error, retrying',
            details:
                'endpoint=$endpoint model=$model attempt=${attempt + 1} nextAttempt=${attempt + 2} error=$e stack=$stackTrace',
          );
          await _delayBeforeNetworkRetry(attempt, cancellationToken);
          continue;
        }
        AppLogService.instance.error(
          'LLM stream request error',
          error: e,
          stackTrace: stackTrace,
          details: 'endpoint=$endpoint model=$model attempt=${attempt + 1}',
        );
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('LLM stream failed after network retries.');
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
      final assistantMsg =
          chat.messages.lastWhere((m) => m.role == 'assistant');
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
      {
        'role': 'user',
        'content': repairPrompt,
      }
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
    Future<void> pumpStream() async {
      try {
        await _streamChatCompletion(
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
          onContent: (chunk) {
            cancellationToken?.throwIfCancelled();
            chunkController.add(chunk);
          },
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
