part of 'ai_chat_viewmodel.dart';

extension AiChatGenerationActions on AiChatViewModel {
  Future<AiChatRecord> _reconciledChatForRun({
    required String chatId,
    required AiChatRecord fallback,
  }) async {
    final memoryChat = _chatById(chatId) ?? fallback;
    try {
      final persistedChats = await _storageService.loadAiChats();
      final persistedIndex = persistedChats.indexWhere(
        (chat) => chat.id == chatId,
      );
      if (persistedIndex < 0) return memoryChat;
      return const AiChatRunStateReconciler().reconcile(
        memoryChat: memoryChat,
        persistedChat: persistedChats[persistedIndex],
      );
    } catch (_) {
      AppLogService.instance.warning(
        'Failed to reconcile persisted AI chat run state',
        details: 'chatId=$chatId',
      );
      return memoryChat;
    }
  }

  // LLM流输出核心实现
  Future<void> _generateAssistantResponse({
    required String chatId,
    required AiChatRecord initialChat,
    required AiChatMessageRecord assistantMessage,
    required String model,
    required List<AiChatMessageRecord> requestMessages,
    required String userRequest,
    required List<String> memorySources,
    required int ragHits,
    required Set<String> selectedConnectionIds,
    required Map<String, ConnectionTargetBinding> connectionTargets,
    required Set<String>? allowedTools,
    required AiRuntimeConnectionSnapshot runtimeConnection,
    required AppLanguage language,
  }) async {
    final generationCompletion = Completer<void>();
    final generationBarrier = generationCompletion.future;
    _generationOperations.add(generationBarrier);
    final cancellationToken = LlmCancellationToken();
    _activeCancellationToken = cancellationToken;
    _activeGenerationChatId = chatId;
    if (_cancelGenerationOnStart) {
      _cancelGenerationOnStart = false;
      cancellationToken.cancel();
    }

    try {
      final settings = runtimeConnection.settings;
      if (_generationCannotPublish(chatId)) return;
      final modelProfile = AgentModelProfile(
        mainModel: model,
        helperModel: settings.helperModel,
        auditModel: settings.auditModel,
        fallbackPolicy: settings.modelFallbackPolicy,
      );

      final translator = AiChatStatusTranslator(language);
      final metricsRecorder = AiChatRunMetricsRecorder(_storageService);
      final runner = AiChatGenerationRunner(runtimeFactory: _runtimeFactory);
      final answer = StringBuffer();
      final forceContextCompression = _consumeContextCompression(chatId);
      _beginStreamingAssistant(
        chatId: chatId,
        assistantCreatedAt: assistantMessage.createdAt,
        status: translator.translateStatus(AgentStatusString.preparing),
      );

      var lastStreamUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

      final runResult = await runner.run(
        chatId: chatId,
        initialChat: initialChat,
        model: model,
        userRequest: userRequest,
        memorySources: memorySources,
        allowedTools: allowedTools,
        forceContextCompression: forceContextCompression,
        cancellationToken: cancellationToken,
        selectedConnectionIds: selectedConnectionIds,
        connectionTargets: connectionTargets,
        language: language,
        runtimeConnectionSnapshot: runtimeConnection,
        requestMessagesJson: _messagesForRequest(
          requestMessages,
          placeholder: assistantMessage,
        ),
        onTextChunk: (chunk) {
          answer.write(chunk);
          _updateStreamingAssistantStatus(
            translator.translateStatus(AgentStatusString.responding),
          );

          final now = DateTime.now();
          if (now.difference(lastStreamUiUpdate) >=
              const Duration(milliseconds: 120)) {
            lastStreamUiUpdate = now;
            _updateStreamingAssistant(answer.toString());
            _triggerScroll();
          }
        },
        onTrace: (event) {
          _updateStreamingAssistantStatus(translator.translateTrace(event));
          _appendTraceToAssistant(
            chatId: chatId,
            assistantCreatedAt: assistantMessage.createdAt,
            event: event,
          );
        },
        requestToolApproval: (request) {
          return _requestToolApproval(
            chatId: chatId,
            request: request,
            translator: translator,
          );
        },
      );
      if (_generationCannotPublish(chatId)) return;

      if (runResult is AiChatRunSuccess) {
        final currentChat = await _reconciledChatForRun(
          chatId: chatId,
          fallback: initialChat,
        );
        if (_generationCannotPublish(chatId)) return;
        final completedMessages = [...currentChat.messages];
        final assistantIndex = completedMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );

        final orchestrator = _runtimeFactory.createOrchestrator();

        if (assistantIndex >= 0) {
          final completedTraces = _ensureAgentRunSummaryTrace(
            completedMessages[assistantIndex].traces,
            runResult.finalOutcome,
            runStats: runResult.runStats,
          );
          final completion = orchestrator.finalizeAssistantTurn(
            initialChat: initialChat,
            assistantMessage: completedMessages[assistantIndex],
            answerText: runResult.answer,
            traces: completedTraces,
          );
          completedMessages[assistantIndex] = completion.assistantMessage
              .copyWith(
                promptTokens: runResult.runStats?.promptTokens,
                completionTokens: runResult.runStats?.completionTokens,
                totalTokens: runResult.runStats?.totalTokens,
                elapsedMs: runResult.runStats?.elapsedMs,
                tokenUsageEstimated: runResult.runStats == null
                    ? null
                    : !runResult.runStats!.usageFromProvider,
                promptCacheHitTokens: runResult.runStats?.promptCacheHitTokens,
                promptCacheMissTokens:
                    runResult.runStats?.promptCacheMissTokens,
                reasoningTokens: runResult.runStats?.reasoningTokens,
                agentRunId: runResult.runId,
              );
        }

        final latestAssistant = latestAssistantMessageForChat(
          currentChat.copyWith(messages: completedMessages),
        );
        final shouldExitPlanMode =
            initialChat.planMode &&
            latestAssistant?.todoSteps.isNotEmpty == true;
        final answeredChat = currentChat.copyWith(
          messages: completedMessages,
          updatedAt: DateTime.now(),
          planMode: shouldExitPlanMode ? false : currentChat.planMode,
        );

        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(answeredChat, activate: false);
        _sending = false;
        notify();
        await _storageService.saveAiChat(answeredChat);
        if (_closing) return;
        if (_deletedGenerationChatIds.contains(chatId)) {
          await _storageService.deleteAiChat(chatId);
          return;
        }

        await metricsRecorder.record(
          modelProfile: modelProfile,
          model: model,
          startedAt: assistantMessage.createdAt,
          finishedAt: DateTime.now(),
          runStats: runResult.runStats,
          ragHits: ragHits,
          success: runResult.succeeded,
          runId: runResult.runId,
        );
      } else if (runResult is AiChatRunCancelled) {
        AppLogService.instance.info(
          'LLM chat UI request cancelled',
          details: 'chatId=$chatId model=$model',
        );
        final currentChat = await _reconciledChatForRun(
          chatId: chatId,
          fallback: initialChat,
        );
        if (_generationCannotPublish(chatId)) return;
        final cancelledMessages = [...currentChat.messages];
        final assistantIndex = cancelledMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );
        final stopStr = translator.translateStatus(AgentStatusString.stopped);
        if (assistantIndex >= 0) {
          final stoppedText = runResult.partialAnswer.trim().isEmpty
              ? stopStr
              : '${runResult.partialAnswer}\n\n$stopStr';
          final traces = _ensureAgentRunSummaryTrace([
            ...cancelledMessages[assistantIndex].traces,
            AiMessageTrace.create(
              kind: 'approval',
              title: 'Stopped by user',
              content: stopStr,
            ),
          ], runResult.finalOutcome);
          cancelledMessages[assistantIndex] = cancelledMessages[assistantIndex]
              .copyWith(
                text: stoppedText,
                traces: traces,
                contextText: _contextTextForAssistant(
                  stoppedText,
                  traces: traces,
                ),
                agentRunId: runResult.runId,
              );
        }
        final cancelledChat = currentChat.copyWith(
          messages: cancelledMessages,
          updatedAt: DateTime.now(),
        );

        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(cancelledChat, activate: false);
        _sending = false;
        notify();
        await _storageService.saveAiChat(cancelledChat);
        if (_closing) return;
        if (_deletedGenerationChatIds.contains(chatId)) {
          await _storageService.deleteAiChat(chatId);
          return;
        }

        await metricsRecorder.record(
          modelProfile: modelProfile,
          model: model,
          startedAt: assistantMessage.createdAt,
          finishedAt: DateTime.now(),
          ragHits: ragHits,
          success: false,
          runId: runResult.runId,
        );
      } else if (runResult is AiChatRunFailed) {
        final currentChat = await _reconciledChatForRun(
          chatId: chatId,
          fallback: initialChat,
        );
        if (_generationCannotPublish(chatId)) return;
        final errorMessages = [...currentChat.messages];
        final assistantIndex = errorMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );
        AiMessageTrace? runSummaryTrace;
        if (assistantIndex >= 0) {
          final traces = _ensureAgentRunSummaryTrace(
            errorMessages[assistantIndex].traces,
            runResult.finalOutcome,
          );
          runSummaryTrace = traces.lastWhere(
            (trace) => trace.kind == 'agent_run_summary',
          );
          final partialText = runResult.partialAnswer;
          if (partialText.trim().isEmpty &&
              errorMessages[assistantIndex].text.isEmpty &&
              errorMessages[assistantIndex].todoSteps.isEmpty) {
            errorMessages.removeAt(assistantIndex);
          } else if (partialText.isNotEmpty) {
            errorMessages[assistantIndex] = errorMessages[assistantIndex]
                .copyWith(
                  text: partialText,
                  contextText: _contextTextForAssistant(
                    partialText,
                    traces: traces,
                  ),
                  traces: traces,
                  agentRunId: runResult.runId,
                );
          } else {
            errorMessages[assistantIndex] = errorMessages[assistantIndex]
                .copyWith(traces: traces, agentRunId: runResult.runId);
          }
        }
        final assistantOwnsRun = errorMessages.any(
          (message) => message.agentRunId == runResult.runId,
        );
        final errorChat = currentChat.copyWith(
          messages: [
            ...errorMessages,
            AiChatMessageRecord(
              role: 'error',
              text: translator.translateFailed(runResult.error),
              traces: assistantOwnsRun || runSummaryTrace == null
                  ? const []
                  : [runSummaryTrace],
              createdAt: DateTime.now(),
              agentRunId: assistantOwnsRun ? null : runResult.runId,
            ),
          ],
          updatedAt: DateTime.now(),
        );

        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(errorChat, activate: false);
        _sending = false;
        notify();
        await _storageService.saveAiChat(errorChat);
        if (_closing) return;
        if (_deletedGenerationChatIds.contains(chatId)) {
          await _storageService.deleteAiChat(chatId);
          return;
        }

        await metricsRecorder.record(
          modelProfile: modelProfile,
          model: model,
          startedAt: assistantMessage.createdAt,
          finishedAt: DateTime.now(),
          ragHits: ragHits,
          success: false,
          runId: runResult.runId,
        );
      }
    } catch (e, stackTrace) {
      if (!_generationCannotPublish(chatId)) {
        AppLogService.instance.error(
          'LLM chat UI request failed unexpectedly',
          error: e,
          stackTrace: stackTrace,
          details: 'chatId=$chatId model=$model',
        );
      }
    } finally {
      _clearStreamingAssistant(
        chatId: chatId,
        assistantCreatedAt: assistantMessage.createdAt,
      );
      _sending = false;
      if (_pendingApproval?.chatId == chatId) {
        _pendingApproval = null;
      }
      if (identical(_activeCancellationToken, cancellationToken)) {
        _activeCancellationToken = null;
      }
      if (_activeGenerationChatId == chatId) {
        _activeGenerationChatId = null;
      }
      _deletedGenerationChatIds.remove(chatId);
      notify();
      _triggerScroll();
      _generationOperations.remove(generationBarrier);
      if (!generationCompletion.isCompleted) generationCompletion.complete();
    }
  }

  bool _generationCannotPublish(String chatId) =>
      _closing || _deletedGenerationChatIds.contains(chatId);
}
