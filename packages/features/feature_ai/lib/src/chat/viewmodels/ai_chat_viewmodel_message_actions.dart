part of 'ai_chat_viewmodel.dart';

extension AiChatMessageActions on AiChatViewModel {
  void _reserveSendPreparation() {
    _sendPreparationCancelled = false;
    _sendCommitInProgress = false;
    _cancelGenerationOnStart = false;
    _sendPreparationInFlight = true;
    _sending = true;
    notify();
  }

  void _releaseSendPreparation() {
    final changed = _sendPreparationInFlight || _sending;
    _sendPreparationInFlight = false;
    _sendCommitInProgress = false;
    _cancelGenerationOnStart = false;
    _sending = false;
    if (changed) notify();
  }

  Future<AiChatRecord?> _enablePlanModeForChat(AiChatRecord chat) async {
    if (chat.id != _activeChatId || !_tryBeginChatStateWrite()) return null;
    try {
      final updated = chat.copyWith(
        planMode: true,
        updatedAt: DateTime.now(),
        clearApprovedPlan: true,
      );
      await _storageService.saveAiChat(updated);
      _replaceChat(updated, activate: false);
      notify();
      return updated;
    } finally {
      _endChatStateWrite();
    }
  }

  Future<({AiChatRecord chat, AiRuntimeConnectionSnapshot runtimeConnection})?>
  _preparePlanModeSend(AiChatRecord chat) async {
    if (chat.id != _activeChatId || !_tryBeginChatStateWrite()) return null;
    try {
      final runtimeConnection = await _storageService
          .loadAiRuntimeConnectionSnapshot();
      final updated = chat.copyWith(
        planMode: true,
        updatedAt: DateTime.now(),
        clearApprovedPlan: true,
      );
      await _storageService.saveAiChat(updated);
      _replaceChat(updated, activate: false);
      notify();
      return (chat: updated, runtimeConnection: runtimeConnection);
    } finally {
      _endChatStateWrite();
    }
  }

  // 发送逻辑
  Future<SendTextResult> sendText({
    required String text,
    AiApprovedPlanRef? approvedPlanRef,
  }) async {
    var activeChat = this.activeChat;
    if (text.isEmpty) return const SendTextEmptyText();
    if (_sending ||
        _sendPreparationInFlight ||
        _planApprovalInFlight ||
        _chatStateWritesInFlight > 0) {
      return const SendTextAlreadySending();
    }
    if (activeChat == null) return const SendTextNoActiveChat();
    final turnInputSnapshot = _captureTurnInputSnapshot(chatId: activeChat.id);

    var targetText = text.trim();
    AiRuntimeConnectionSnapshot? capturedRuntimeConnection;
    if (targetText.startsWith('/')) {
      final planCommand = parsePlanCommand(targetText);
      if (planCommand?.hasArguments == true) {
        final prepared = await _preparePlanModeSend(activeChat);
        if (prepared == null) return const SendTextAlreadySending();

        activeChat = prepared.chat;
        capturedRuntimeConnection = prepared.runtimeConnection;
        targetText = planCommand!.arguments;
      } else {
        final handledResult = await _executeSlashCommand(
          chatId: activeChat.id,
          input: targetText,
        );
        if (handledResult != null) {
          return handledResult;
        }
      }
    }

    _reserveSendPreparation();
    try {
      final runtimeConnection =
          capturedRuntimeConnection ??
          await _storageService.loadAiRuntimeConnectionSnapshot();
      final settings = runtimeConnection.settings;
      if (_sendPreparationCancelled || !_sendPreparationInFlight) {
        _releaseSendPreparation();
        return const SendTextStartCancelled();
      }
      final currentModel = settings.model.trim();
      if (!runtimeConnection.hasApiKey) {
        AppLogService.instance.warning(
          'LLM chat blocked: API key missing or invalid',
          details: 'model=$currentModel',
        );
        _releaseSendPreparation();
        return const SendTextApiKeyMissing();
      }

      return await _startTextGeneration(
        chat: activeChat,
        targetText: targetText,
        runtimeConnection: runtimeConnection,
        approvedPlanRef: approvedPlanRef,
        turnInputSnapshot: turnInputSnapshot,
        preparationReserved: true,
      );
    } catch (_) {
      _releaseSendPreparation();
      rethrow;
    }
  }

  Future<SendTextResult> _startTextGeneration({
    required AiChatRecord chat,
    required String targetText,
    required AiRuntimeConnectionSnapshot runtimeConnection,
    AiApprovedPlanRef? approvedPlanRef,
    _ChatTurnInputSnapshot? turnInputSnapshot,
    bool Function()? canCommit,
    bool preparationReserved = false,
  }) async {
    if (preparationReserved) {
      if (_sendPreparationCancelled) {
        return const SendTextStartCancelled();
      }
      if (!_sendPreparationInFlight || !_sending) {
        return const SendTextAlreadySending();
      }
    } else if (_sending || _sendPreparationInFlight) {
      return const SendTextAlreadySending();
    }
    if (canCommit != null && !canCommit()) {
      return const SendTextTargetChanged();
    }

    if (!preparationReserved) {
      _reserveSendPreparation();
    }

    try {
      final settings = runtimeConnection.settings;
      final currentModel = settings.model.trim();
      final chatId = chat.id;
      final now = DateTime.now();
      final turnInput =
          turnInputSnapshot ?? _captureTurnInputSnapshot(chatId: chatId);

      // RAG 检索
      final attachments = List<AiChatAttachment>.from(turnInput.attachments);
      final orchestrator = _runtimeFactory.createOrchestrator();

      final preparedTurn = await orchestrator.prepareTurn(
        chat: chat,
        text: targetText,
        createdAt: now,
        language: turnInput.language,
        attachments: attachments,
        selectedConnectionIds: turnInput.selectedConnectionIds,
        connectionTargets: turnInput.connectionTargets,
        approvedPlanRef: approvedPlanRef,
        ragEnabled: turnInput.ragEnabled,
        ragSearchMode: turnInput.ragSearchMode,
        ragLimit: turnInput.ragTopN,
        ragAliyunApiKey: runtimeConnection.aliyunApiKey,
      );
      if (_sendPreparationCancelled || !_sendPreparationInFlight) {
        _releaseSendPreparation();
        return const SendTextStartCancelled();
      }
      if (canCommit != null && !canCommit()) {
        _releaseSendPreparation();
        return const SendTextTargetChanged();
      }
      final userMessage = preparedTurn.userMessage;

      final assistantMessage = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        traces: preparedTurn.assistantMessage.traces,
        createdAt: now,
      );
      final nextMessages = [...chat.messages, userMessage, assistantMessage];
      final nextChat = chat.copyWith(
        title: chat.messages.isEmpty ? _titleFrom(targetText) : null,
        model: currentModel.isNotEmpty ? currentModel : chat.model,
        messages: nextMessages,
        updatedAt: now,
        approvedPlan: approvedPlanRef,
      );

      _sendCommitInProgress = true;
      await _storageService.saveAiChat(nextChat);

      _replaceChat(nextChat, activate: _activeChatId == chatId);
      _removePendingAttachmentSnapshot(attachments);
      _toolsExpanded = false;
      notify();
      _triggerScroll();

      unawaited(
        _generateAssistantResponse(
          chatId: chatId,
          initialChat: nextChat,
          assistantMessage: assistantMessage,
          model: currentModel.isNotEmpty ? currentModel : nextChat.model,
          requestMessages: nextMessages,
          userRequest: targetText,
          memorySources: preparedTurn.memorySources,
          ragHits: preparedTurn.ragHits,
          selectedConnectionIds: turnInput.selectedConnectionIds,
          connectionTargets: turnInput.connectionTargets,
          allowedTools: turnInput.allowedTools,
          runtimeConnection: runtimeConnection,
          language: turnInput.language,
        ),
      );
      _sendCommitInProgress = false;
      _sendPreparationInFlight = false;

      return const SendTextSuccess();
    } catch (_) {
      _releaseSendPreparation();
      rethrow;
    }
  }

  void _removePendingAttachmentSnapshot(
    Iterable<AiChatAttachment> consumedAttachments,
  ) {
    for (final consumed in consumedAttachments) {
      final index = _pendingAttachments.indexWhere(
        (pending) => identical(pending, consumed),
      );
      if (index >= 0) {
        _pendingAttachments.removeAt(index);
      }
    }
  }

  _ChatTurnInputSnapshot _captureTurnInputSnapshot({
    required String chatId,
    bool includeAttachments = true,
  }) {
    final allowedTools = _chatAllowedTools[chatId];
    final connectionTargets = <String, ConnectionTargetBinding>{};
    for (final id in _selectedConnectionIds) {
      final connection = _storageService.getConnection(id);
      if (connection != null) {
        connectionTargets[id] = ConnectionTargetBinding.fromConfig(connection);
      }
    }
    return _ChatTurnInputSnapshot(
      attachments: includeAttachments
          ? List<AiChatAttachment>.unmodifiable(_pendingAttachments)
          : const <AiChatAttachment>[],
      selectedConnectionIds: Set<String>.unmodifiable(_selectedConnectionIds),
      connectionTargets: Map<String, ConnectionTargetBinding>.unmodifiable(
        connectionTargets,
      ),
      allowedTools: allowedTools == null
          ? null
          : Set<String>.unmodifiable(allowedTools),
      ragEnabled: _appSettings.ragEnabled,
      ragSearchMode: switch (_appSettings.ragSearchMode) {
        'vector' => 'vector',
        'hybrid' => 'hybrid',
        _ => 'bm25',
      },
      ragTopN: _appSettings.ragTopN.clamp(1, 10),
      language: _appSettings.language,
    );
  }

  Future<void> retryTodoStep(String taskId) async {
    if (!_tryBeginChatStateWrite()) return;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;

      final messages = [...activeChat.messages];
      bool found = false;

      for (var mIdx = 0; mIdx < messages.length; mIdx++) {
        final msg = messages[mIdx];
        if (msg.todoSteps.isEmpty) continue;

        final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
        if (sIdx != -1) {
          final steps = [...msg.todoSteps];
          steps[sIdx] = steps[sIdx].copyWith(
            status: StepStatus.pending,
            stdout: '',
            stderr: '',
            exitCode: null,
          );
          messages[mIdx] = msg.copyWith(todoSteps: steps);
          found = true;
          break;
        }
      }

      if (found) {
        final updated = activeChat.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        );
        await _storageService.saveAiChat(updated);
        _replaceChat(updated, sort: false, activate: false);
        notify();
      }
    } finally {
      _endChatStateWrite();
    }
  }

  Future<void> skipTodoStep(String taskId, String reason) async {
    if (!_tryBeginChatStateWrite()) return;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;

      final messages = [...activeChat.messages];
      bool found = false;

      for (var mIdx = 0; mIdx < messages.length; mIdx++) {
        final msg = messages[mIdx];
        if (msg.todoSteps.isEmpty) continue;

        final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
        if (sIdx != -1) {
          final steps = [...msg.todoSteps];
          steps[sIdx] = steps[sIdx].copyWith(
            status: StepStatus.skipped,
            stdout: 'Skipped: $reason',
            exitCode: null,
          );
          messages[mIdx] = msg.copyWith(todoSteps: steps);
          found = true;
          break;
        }
      }

      if (found) {
        final updated = activeChat.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        );
        await _storageService.saveAiChat(updated);
        _replaceChat(updated, sort: false, activate: false);
        notify();
      }
    } finally {
      _endChatStateWrite();
    }
  }

  void stopGeneration() {
    if (!_sending) return;
    if (_sendPreparationInFlight) {
      if (_sendCommitInProgress) {
        _cancelGenerationOnStart = true;
      } else {
        _sendPreparationCancelled = true;
        _sendPreparationInFlight = false;
        _sending = false;
      }
      notify();
      return;
    }
    _activeCancellationToken?.cancel();
    final pending = _pendingApproval;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(
        const AiToolApprovalDecision.rejected(abort: true),
      );
    }
    _pendingApproval = null;
    notify();
  }

  Future<void> regenerateAssistant(int messageIndex) async {
    if (!_tryBeginChatStateWrite()) return;
    late AiChatRecord nextChat;
    late AiChatMessageRecord assistantMessage;
    late List<AiChatMessageRecord> nextMessages;
    late String nextModel;
    late String userRequest;
    late _ChatTurnInputSnapshot turnInputSnapshot;
    late AiRuntimeConnectionSnapshot runtimeConnection;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;
      if (messageIndex < 0 || messageIndex >= activeChat.messages.length) {
        return;
      }
      final target = activeChat.messages[messageIndex];
      if (target.role != 'assistant') return;
      turnInputSnapshot = _captureTurnInputSnapshot(
        chatId: activeChat.id,
        includeAttachments: false,
      );

      runtimeConnection = await _storageService
          .loadAiRuntimeConnectionSnapshot();
      final settings = runtimeConnection.settings;
      if (!runtimeConnection.hasApiKey) return;

      final prefix = activeChat.messages.take(messageIndex).toList();
      if (prefix.where((message) => message.role == 'user').isEmpty) return;
      final now = DateTime.now();
      assistantMessage = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        createdAt: now,
      );
      nextMessages = [...prefix, assistantMessage];
      nextModel = settings.model.trim().isNotEmpty
          ? settings.model
          : activeChat.model;
      nextChat = activeChat.copyWith(
        model: nextModel,
        messages: nextMessages,
        updatedAt: now,
        clearApprovedPlan: true,
      );
      userRequest = prefix.lastWhere((message) => message.role == 'user').text;

      await _storageService.saveAiChat(nextChat);
      _invalidateHistoryRewriteState(activeChat.id);
      _replaceChat(nextChat, activate: false);
      _sending = true;
      notify();
      _triggerScroll();
    } finally {
      _endChatStateWrite();
    }

    await _generateAssistantResponse(
      chatId: nextChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      userRequest: userRequest,
      memorySources: const [],
      ragHits: 0,
      selectedConnectionIds: turnInputSnapshot.selectedConnectionIds,
      connectionTargets: turnInputSnapshot.connectionTargets,
      allowedTools: turnInputSnapshot.allowedTools,
      runtimeConnection: runtimeConnection,
      language: turnInputSnapshot.language,
    );
  }

  Future<void> editUserMessage(
    int messageIndex,
    String trimmedEditedText,
  ) async {
    if (trimmedEditedText.isEmpty || !_tryBeginChatStateWrite()) return;
    late AiChatRecord nextChat;
    late AiChatMessageRecord assistantMessage;
    late List<AiChatMessageRecord> nextMessages;
    late String nextModel;
    late _ChatTurnInputSnapshot turnInputSnapshot;
    late AiRuntimeConnectionSnapshot runtimeConnection;
    late List<String> memorySources;
    late int ragHits;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;
      if (messageIndex < 0 || messageIndex >= activeChat.messages.length) {
        return;
      }
      final target = activeChat.messages[messageIndex];
      if (target.role != 'user') return;
      turnInputSnapshot = _captureTurnInputSnapshot(
        chatId: activeChat.id,
        includeAttachments: false,
      );

      final targetIndex = activeChat.messages.indexWhere(
        (message) =>
            message.role == 'user' && message.createdAt == target.createdAt,
      );
      if (targetIndex < 0 || targetIndex >= activeChat.messages.length) {
        return;
      }

      runtimeConnection = await _storageService
          .loadAiRuntimeConnectionSnapshot();
      final settings = runtimeConnection.settings;
      if (!runtimeConnection.hasApiKey) return;

      final currentTarget = activeChat.messages[targetIndex];
      if (currentTarget.role != 'user') return;

      final now = DateTime.now();
      final preparedTurn = await _runtimeFactory
          .createOrchestrator()
          .prepareTurn(
            chat: activeChat,
            text: trimmedEditedText,
            createdAt: now,
            language: turnInputSnapshot.language,
            attachments: currentTarget.attachments,
            selectedConnectionIds: turnInputSnapshot.selectedConnectionIds,
            connectionTargets: turnInputSnapshot.connectionTargets,
            ragEnabled: turnInputSnapshot.ragEnabled,
            ragSearchMode: turnInputSnapshot.ragSearchMode,
            ragLimit: turnInputSnapshot.ragTopN,
            ragAliyunApiKey: runtimeConnection.aliyunApiKey,
          );
      memorySources = preparedTurn.memorySources;
      ragHits = preparedTurn.ragHits;
      final editedUser = preparedTurn.userMessage;
      assistantMessage = preparedTurn.assistantMessage;
      nextMessages = [
        ...activeChat.messages.take(targetIndex),
        editedUser,
        assistantMessage,
      ];
      nextModel = settings.model.trim().isNotEmpty
          ? settings.model
          : activeChat.model;
      nextChat = activeChat.copyWith(
        title: targetIndex == 0 ? _titleFrom(trimmedEditedText) : null,
        model: nextModel,
        messages: nextMessages,
        updatedAt: now,
        clearApprovedPlan: true,
      );

      await _storageService.saveAiChat(nextChat);
      _invalidateHistoryRewriteState(activeChat.id);
      _replaceChat(nextChat, activate: false);
      _sending = true;
      notify();
      _triggerScroll();
    } finally {
      _endChatStateWrite();
    }

    await _generateAssistantResponse(
      chatId: nextChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      userRequest: trimmedEditedText,
      memorySources: memorySources,
      ragHits: ragHits,
      selectedConnectionIds: turnInputSnapshot.selectedConnectionIds,
      connectionTargets: turnInputSnapshot.connectionTargets,
      allowedTools: turnInputSnapshot.allowedTools,
      runtimeConnection: runtimeConnection,
      language: turnInputSnapshot.language,
    );
  }

  void _invalidateHistoryRewriteState(String chatId) {
    if (_pendingPlanWarningSnapshot?.chat.id == chatId) {
      _pendingPlanWarningSnapshot = null;
    }
    _pendingForceCompressionChats.remove(chatId);
  }

  Future<void> branchFromAssistant(int messageIndex) async {
    if (!_tryBeginChatStateWrite()) return;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;
      if (messageIndex < 0 || messageIndex >= activeChat.messages.length) {
        return;
      }
      final target = activeChat.messages[messageIndex];
      if (target.role != 'assistant') return;

      final now = DateTime.now();
      final strings = AiStrings(_appSettings.language);
      final branch = AiChatRecord(
        id: 'ai-${now.microsecondsSinceEpoch}',
        title: '${activeChat.title} ${strings.branch}',
        model: activeChat.model,
        messages: activeChat.messages.take(messageIndex + 1).toList(),
        createdAt: now,
        updatedAt: now,
      );

      await _storageService.saveAiChat(branch);
      _chats = [branch, ..._chats];
      if (branch.messages.isNotEmpty) {
        _savedHistoryChats = [branch, ..._savedHistoryChats];
      }
      _activeChatId = branch.id;
      notify();
      _triggerScroll();
    } finally {
      _endChatStateWrite();
    }
  }

  // 上下文 Token 压缩与估计逻辑 (吸收自原 chat_token_compression.dart)
  // 上下文 Token 压缩与估计逻辑
}
