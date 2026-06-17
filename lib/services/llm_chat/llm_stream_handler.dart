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
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool planMode = false,
  }) async {
    final buffer = StringBuffer();
    await for (final chunk in _streamImpl(
      messages: messages,
      modelOverride: modelOverride,
      requestToolApproval: requestToolApproval,
      onStats: onStats,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
      userRequest: userRequest,
      selectedConnectionIds: selectedConnectionIds,
      hasWebViewSession: hasWebViewSession,
      hasApprovedPlan: hasApprovedPlan,
      memorySources: memorySources,
      planMode: planMode,
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
    Set<String>? allowedTools,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool forceContextCompression = false,
    bool planMode = false,
  }) async* {
    final settings = await storageService.loadAiConnectionSettings();
    final runStartedAt = DateTime.now();
    final runId = const Uuid().v4();
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

    final hiddenTools = toolSelection.decisions.where((d) => !d.selected).toList();
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
          'requestedCapabilities': toolSelection.requestedCapabilities.map((c) => c.name).toList(),
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
        yield multiAgentResult.memoryContent;
        final elapsedMs =
            DateTime.now().difference(runStartedAt).inMilliseconds;
        final promptTokens =
            LlmChatService.estimateMessagesTokens(workingMessages);
        final completionTokens =
            LlmChatService.estimateTextTokens(multiAgentResult.memoryContent);
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
        return;
      }
    }

    final visibleOutput = StringBuffer();
    try {
    for (var round = 0;; round++) {
      cancellationToken?.throwIfCancelled();
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
      _emitReasoningTrace(onTrace, response.reasoningContent);

      if (response.toolCalls.isEmpty) {
        final answer =
            content.toString().trim().isNotEmpty ? content.toString() : 'Done.';
        if (content.isEmpty) yield answer;
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
            totalTokens:
                response.usage?.totalTokens ?? promptTokens + completionTokens,
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
        runId: runId,
        startedAt: runStartedAt,
        finishedAt: finishedAt,
        model: model,
        helperModel: helperModel,
        auditModel: auditModel,
        planMode: planMode,
        promptTokens: LlmChatService.estimateMessagesTokens(workingMessages),
        completionTokens: LlmChatService.estimateTextTokens(visibleOutput.toString()),
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
}
