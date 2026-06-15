// ignore_for_file: invalid_use_of_protected_member
part of '../llm_chat_screen.dart';

extension _ChatGeneration on _LlmChatScreenState {
  Future<void> _send(BuildContext context, _AiStrings strings) async {
    final text = (_inputController.text.trim());
    await _sendText(context, strings, text: text, clearInput: true);
  }

  Future<void> _sendText(
    BuildContext context,
    _AiStrings strings, {
    required String text,
    required bool clearInput,
  }) async {
    final activeChat = _activeChat;
    if (text.isEmpty || _sending || activeChat == null) return;
    final normalizedText = text.trim();
    if (normalizedText.startsWith('/')) {
      final handled = await _executeSlashCommand(
        chatId: activeChat.id,
        input: normalizedText,
        strings: strings,
      );
      if (!mounted) {
        return;
      }
      if (handled && clearInput) {
        setState(() {
          _inputController.clear();
          _toolsExpanded = false;
        });
      }
      return;
    }

    final storage = context.read<StorageService>();
    final appSettings = context.read<AppSettings>();
    final ragService = context.read<RagService>();

    final settings = await storage.loadAiConnectionSettings();
    final currentModel = settings.model.trim();
    if (!settings.hasApiKey) {
      AppLogService.instance.warning(
        'LLM chat blocked: API key missing or invalid',
        details: 'model=$currentModel',
      );
      if (!context.mounted) return;
      await _showSettings(context, strings);
      return;
    }

    final chatId = activeChat.id;
    final now = DateTime.now();

    // RAG 知识库检索
    List<RagChunk> ragChunks = const [];
    if (appSettings.ragEnabled) {
      try {
        ragChunks = await ragService.retrieve(normalizedText);
      } catch (e) {
        AppLogService.instance.warning('RAG retrieval failed in sendText: $e');
      }
    }

    final userContextText =
        await _contextTextForUser(text, ragChunks: ragChunks);
    final attachments = List<AiChatAttachment>.from(_pendingAttachments);
    final userMessage = AiChatMessageRecord(
      role: 'user',
      text: text,
      contextText: userContextText,
      attachments: attachments,
      createdAt: now,
    );

    // 构建 RAG 的 UI 引用痕迹 (Citation Traces)
    final assistantTraces = <AiMessageTrace>[];
    if (ragChunks.isNotEmpty) {
      final traceContent = StringBuffer();
      final isEn = appSettings.isEnglish;
      for (final chunk in ragChunks) {
        traceContent.writeln(isEn
            ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
            : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})');
        traceContent.writeln('---');
        traceContent.writeln(chunk.text);
        traceContent.writeln('========================================\n');
      }
      assistantTraces.add(AiMessageTrace(
        id: 'rag-${now.microsecondsSinceEpoch}',
        kind: 'rag_context',
        title: isEn ? 'Knowledge Base Retrieval (RAG)' : '知识库检索 (RAG)',
        content: traceContent.toString(),
        createdAt: now,
      ));
    }

    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      traces: assistantTraces,
      createdAt: now,
    );
    final nextMessages = [
      ...activeChat.messages,
      userMessage,
      assistantMessage,
    ];
    final nextChat = activeChat.copyWith(
      title: activeChat.messages.isEmpty ? _titleFrom(text, strings) : null,
      model: currentModel.isNotEmpty ? currentModel : activeChat.model,
      messages: nextMessages,
      updatedAt: now,
    );

    setState(() {
      _replaceChat(nextChat);
      _sending = true;
      if (_scrollController.hasClients) {
        _isUserAtBottom = _isNearBottom(_scrollController.position);
      } else {
        _isUserAtBottom = true;
      }
      if (clearInput) _inputController.clear();
      _pendingAttachments.clear();
      _toolsExpanded = false;
    });
    await storage.saveAiChat(nextChat);
    _scrollToBottom();

    await _generateAssistantResponse(
      chatId: chatId,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: currentModel.isNotEmpty ? currentModel : nextChat.model,
      requestMessages: nextMessages,
      strings: strings,
    );
  }

  void _continueAfterTimeout(_AiStrings strings) {
    _sendText(
      context,
      strings,
      text: strings.continueAfterTimeoutPrompt,
      clearInput: false,
    );
  }

  bool _isTimeoutError(String text) {
    final lower = text.toLowerCase();
    return lower.contains('timeout') || text.contains('超时');
  }

  Future<void> _generateAssistantResponse({
    required String chatId,
    required AiChatRecord initialChat,
    required AiChatMessageRecord assistantMessage,
    required String model,
    required List<AiChatMessageRecord> requestMessages,
    required _AiStrings strings,
  }) async {
    final storage = context.read<StorageService>();
    final ssh = context.read<SshService>();
    final sftp = context.read<SftpService>();
    final performanceMonitor = context.read<PerformanceMonitorService>();
    final appSettings = context.read<AppSettings>();
    final playbookService = context.read<PlaybookService>();
    final language = appSettings.language;

    final settings = await storage.loadAiConnectionSettings();
    final service = LlmChatService(
      storageService: storage,
      toolService: AiToolService(
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
        performanceMonitorToolService: PerformanceMonitorToolService(
          performanceMonitor,
        ),
        appSettings: appSettings,
        playbookService: playbookService,
        clientWebViewSessionId: chatId,
      ),
      language: language,
      useCustomPrompts: settings.useCustomPrompts,
      customSystemPrompt: settings.customSystemPrompt,
      customPlannerPrompt: settings.customPlannerPrompt,
      customOperatorPrompt: settings.customOperatorPrompt,
      customExplorePrompt: settings.customExplorePrompt,
      customReviewerPrompt: settings.customReviewerPrompt,
      customSummarizerPrompt: settings.customSummarizerPrompt,
      customCoordinatorPrompt: settings.customCoordinatorPrompt,
    );
    final cancellationToken = LlmCancellationToken();
    _activeCancellationToken = cancellationToken;
    final answer = StringBuffer();
    final forceContextCompression = _consumeContextCompression(chatId);
    final allowedTools = _chatAllowedTools[chatId];
    if (mounted) {
      setState(() {
        _beginStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
          status: strings.assistantPreparing,
        );
      });
    }

    try {
      LlmRunStats? runStats;
      var lastStreamUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
      await for (final chunk in service.stream(
        modelOverride: model,
        onStats: (stats) => runStats = stats,
        onTrace: (event) {
          _updateStreamingAssistantStatus(
            _assistantStatusForTrace(event, strings),
          );
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
          );
        },
        allowedTools: allowedTools,
        forceContextCompression: forceContextCompression,
        cancellationToken: cancellationToken,
        planMode: initialChat.planMode,
        messages: _messagesForRequest(
          requestMessages,
          placeholder: assistantMessage,
        ),
      )) {
        answer.write(chunk);
        _updateStreamingAssistantStatus(strings.assistantResponding);
        if (!mounted) return;
        final now = DateTime.now();
        if (now.difference(lastStreamUiUpdate) <
            const Duration(milliseconds: 120)) {
          continue;
        }
        lastStreamUiUpdate = now;
        _updateStreamingAssistant(answer.toString());
        _scrollToBottom();
      }
      if (!mounted) return;
      final currentChat = _chatById(chatId) ?? initialChat;
      final completedMessages = [...currentChat.messages];
      final assistantIndex = completedMessages.indexWhere(
        (message) =>
            message.role == 'assistant' &&
            message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0) {
        final existingSteps = completedMessages[assistantIndex].todoSteps;
        final todoSteps = existingSteps.isNotEmpty
            ? existingSteps
            : (initialChat.planMode
                ? _parseTodoStepsFromText(answer.toString())
                : const <AiTodoStep>[]);
        completedMessages[assistantIndex] =
            completedMessages[assistantIndex].copyWith(
          text: answer.toString(),
          contextText: _contextTextForAssistant(
            answer.toString(),
            traces: completedMessages[assistantIndex].traces,
          ),
          promptTokens: runStats?.promptTokens,
          completionTokens: runStats?.completionTokens,
          totalTokens: runStats?.totalTokens,
          elapsedMs: runStats?.elapsedMs,
          tokenUsageEstimated:
              runStats == null ? null : !runStats!.usageFromProvider,
          promptCacheHitTokens: runStats?.promptCacheHitTokens,
          promptCacheMissTokens: runStats?.promptCacheMissTokens,
          reasoningTokens: runStats?.reasoningTokens,
          todoSteps: todoSteps,
        );
      }
      final answeredChat = currentChat.copyWith(
        messages: completedMessages,
        updatedAt: DateTime.now(),
        planMode: initialChat.planMode ? false : currentChat.planMode,
      );
      setState(() {
        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(answeredChat);
      });
      await storage.saveAiChat(answeredChat);
    } on LlmCancelledException {
      AppLogService.instance.info(
        'LLM chat UI request cancelled',
        details: 'chatId=$chatId model=$model',
      );
      if (!mounted) return;
      final currentChat = _chatById(chatId) ?? initialChat;
      final cancelledMessages = [...currentChat.messages];
      final assistantIndex = cancelledMessages.indexWhere(
        (message) =>
            message.role == 'assistant' &&
            message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0) {
        final stoppedText = answer.toString().trim().isEmpty
            ? strings.stopped
            : '${answer.toString()}\n\n${strings.stopped}';
        final traces = [
          ...cancelledMessages[assistantIndex].traces,
          AiMessageTrace.create(
            kind: 'approval',
            title: 'Stopped by user',
            content: strings.stopped,
          ),
        ];
        cancelledMessages[assistantIndex] =
            cancelledMessages[assistantIndex].copyWith(
          text: stoppedText,
          traces: traces,
          contextText: _contextTextForAssistant(stoppedText, traces: traces),
        );
      }
      final cancelledChat = currentChat.copyWith(
        messages: cancelledMessages,
        updatedAt: DateTime.now(),
      );
      setState(() {
        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(cancelledChat);
      });
      await storage.saveAiChat(cancelledChat);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM chat UI request failed',
        error: e,
        stackTrace: stackTrace,
        details: 'chatId=$chatId model=$model',
      );
      if (!mounted) return;
      final currentChat = _chatById(chatId) ?? initialChat;
      final errorMessages = [...currentChat.messages];
      final assistantIndex = errorMessages.indexWhere(
        (message) =>
            message.role == 'assistant' &&
            message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0) {
        final partialText = answer.toString();
        if (partialText.trim().isEmpty &&
            errorMessages[assistantIndex].text.isEmpty) {
          errorMessages.removeAt(assistantIndex);
        } else if (partialText.isNotEmpty) {
          errorMessages[assistantIndex] =
              errorMessages[assistantIndex].copyWith(
            text: partialText,
            contextText: _contextTextForAssistant(
              partialText,
              traces: errorMessages[assistantIndex].traces,
            ),
          );
        }
      }
      final errorChat = currentChat.copyWith(
        messages: [
          ...errorMessages,
          AiChatMessageRecord(
            role: 'error',
            text: strings.failed(e),
            createdAt: DateTime.now(),
          ),
        ],
        updatedAt: DateTime.now(),
      );
      setState(() {
        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(errorChat);
      });
      await storage.saveAiChat(errorChat);
    } finally {
      if (mounted) {
        setState(() {
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
        });
        _scrollToBottom();
      }
    }
  }

  Future<AiToolApprovalDecision> _requestToolApproval({
    required String chatId,
    required AiToolApprovalRequest request,
  }) {
    final completer = Completer<AiToolApprovalDecision>();
    if (!mounted) {
      return Future.value(const AiToolApprovalDecision.rejected());
    }
    _updateStreamingAssistantStatus(
      _AiStrings(context.read<AppSettings>().language)
          .assistantAwaitingApproval(request.connectionName),
    );
    setState(() {
      _pendingApproval = _PendingToolApproval(
        chatId: chatId,
        request: request,
        completer: completer,
      );
    });
    _scrollToBottom();
    return completer.future;
  }

  void _resolvePendingApproval({required bool approved}) {
    final pending = _pendingApproval;
    if (pending == null || pending.completer.isCompleted) return;
    setState(() => _pendingApproval = null);
    pending.completer.complete(
      approved
          ? const AiToolApprovalDecision.approved()
          : const AiToolApprovalDecision.rejected(),
    );
  }

  void _stopGeneration() {
    if (!_sending) return;
    _activeCancellationToken?.cancel();
    final pending = _pendingApproval;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(
        const AiToolApprovalDecision.rejected(abort: true),
      );
    }
    setState(() => _pendingApproval = null);
  }

  Future<bool> _confirmChatAction({
    required String title,
    required String content,
    required String confirmLabel,
    required _AiStrings strings,
  }) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _confirmRegenerateAssistant(
    int messageIndex,
    _AiStrings strings,
  ) async {
    final en = strings.language == AppLanguage.en;
    final confirmed = await _confirmChatAction(
      title: en ? 'Regenerate this reply?' : '确认重新生成这条回复吗？',
      content: en
          ? 'This will replace this assistant message and regenerate from this point. Continue?'
          : '这会替换这条 AI 回复并从该位置重新生成。确定继续吗？',
      confirmLabel: en ? 'Regenerate' : '重新生成',
      strings: strings,
    );
    if (!confirmed) return;
    await _regenerateAssistant(messageIndex);
  }

  Future<void> _confirmBranchFromAssistant(
    int messageIndex,
    _AiStrings strings,
  ) async {
    final en = strings.language == AppLanguage.en;
    final confirmed = await _confirmChatAction(
      title: en ? 'Create a chat branch?' : '确认创建聊天分支吗？',
      content: en
          ? 'This creates a new chat thread from this message and continues independently from here.'
          : '将从该消息创建一个新的聊天分支，并从这里继续新对话。',
      confirmLabel: en ? 'Create branch' : '创建分支',
      strings: strings,
    );
    if (!confirmed) return;
    await _branchFromAssistant(messageIndex, strings);
  }

  Future<void> _regenerateAssistant(int messageIndex) async {
    final strings = _AiStrings(context.read<AppSettings>().language);
    final activeChat = _activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'assistant') return;

    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      if (mounted) await _showSettings(context, strings);
      return;
    }
    if (!mounted) return;

    final prefix = activeChat.messages.take(messageIndex).toList();
    if (prefix.where((message) => message.role == 'user').isEmpty) return;
    final now = DateTime.now();
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [...prefix, assistantMessage];
    final nextModel =
        settings.model.trim().isNotEmpty ? settings.model : activeChat.model;
    final nextChat = activeChat.copyWith(
      model: nextModel,
      messages: nextMessages,
      updatedAt: now,
    );

    setState(() {
      _replaceChat(nextChat);
      _sending = true;
    });
    await storage.saveAiChat(nextChat);
    _scrollToBottom();
    await _generateAssistantResponse(
      chatId: activeChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      strings: strings,
    );
  }

  Future<void> _editUserMessage(int messageIndex, _AiStrings strings) async {
    final activeChat = _activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'user') return;

    final editedText = await _showEditUserDialog(target.text, strings);
    if (!mounted) return;
    if (editedText == null) return;
    final trimmedEditedText = editedText.trim();
    if (trimmedEditedText.isEmpty) return;
    if (!mounted) return;

    final latestActiveChat = _activeChat;
    if (latestActiveChat == null || latestActiveChat.id != activeChat.id) {
      return;
    }
    final targetIndex = latestActiveChat.messages.indexWhere(
      (message) =>
          message.role == 'user' && message.createdAt == target.createdAt,
    );
    if (targetIndex < 0 || targetIndex >= latestActiveChat.messages.length) {
      return;
    }

    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      if (mounted) await _showSettings(context, strings);
      return;
    }
    if (!mounted) return;

    final currentTarget = latestActiveChat.messages[targetIndex];
    if (currentTarget.role != 'user') return;

    final now = DateTime.now();
    final editedUser = currentTarget.copyWith(
      text: trimmedEditedText,
      createdAt: now,
    );
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [
      ...latestActiveChat.messages.take(targetIndex),
      editedUser,
      assistantMessage,
    ];
    final nextModel = settings.model.trim().isNotEmpty
        ? settings.model
        : latestActiveChat.model;
    final nextChat = latestActiveChat.copyWith(
      title: targetIndex == 0 ? _titleFrom(trimmedEditedText, strings) : null,
      model: nextModel,
      messages: nextMessages,
      updatedAt: now,
    );

    setState(() {
      _replaceChat(nextChat);
      _sending = true;
    });
    await storage.saveAiChat(nextChat);
    _scrollToBottom();
    await _generateAssistantResponse(
      chatId: activeChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      strings: strings,
    );
  }

  Future<String?> _showEditUserDialog(
    String text,
    _AiStrings strings,
  ) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _EditUserMessageDialog(
        initialText: text,
        strings: strings,
      ),
    );
  }

  Future<void> _branchFromAssistant(
    int messageIndex,
    _AiStrings strings,
  ) async {
    final activeChat = _activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'assistant') return;

    final now = DateTime.now();
    final branch = AiChatRecord(
      id: 'ai-${now.microsecondsSinceEpoch}',
      title: '${activeChat.title} ${strings.branchSuffix}',
      model: activeChat.model,
      messages: activeChat.messages.take(messageIndex + 1).toList(),
      createdAt: now,
      updatedAt: now,
    );
    setState(() {
      _chats = [branch, ..._chats];
      if (branch.messages.isNotEmpty) {
        _savedHistoryChats = [branch, ..._savedHistoryChats];
        _historyLoadStarted = true;
      }
      _activeChatId = branch.id;
    });
    await context.read<StorageService>().saveAiChat(branch);
    _scrollToBottom();
  }

  void _appendTraceToAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required LlmTraceEvent event,
  }) {
    if (!mounted) return;
    final currentChat = _chatById(chatId);
    if (currentChat == null) return;
    final messages = [...currentChat.messages];
    final assistantIndex = messages.indexWhere(
      (message) =>
          message.role == 'assistant' &&
          message.createdAt == assistantCreatedAt,
    );
    if (assistantIndex < 0) return;
    messages[assistantIndex] = messages[assistantIndex].copyWith(
      traces: [
        ...messages[assistantIndex].traces,
        AiMessageTrace.create(
          kind: event.kind,
          title: event.title,
          content: event.content,
        ),
      ],
    );
    setState(() {
      _replaceChat(
        currentChat.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        ),
        sort: false,
      );
    });
    _scrollToBottom();
  }

  void _beginStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required String status,
  }) {
    _streamingAssistantTarget = _StreamingAssistantTarget(
      chatId: chatId,
      assistantCreatedAt: assistantCreatedAt,
    );
    _streamingAssistantText.value = '';
    _streamingAssistantStatus.value = status;
  }

  void _updateStreamingAssistant(String text) {
    if (_streamingAssistantText.value == text) return;
    _streamingAssistantText.value = text;
  }

  void _updateStreamingAssistantStatus(String status) {
    if (!mounted || _streamingAssistantTarget == null) return;
    if (_streamingAssistantStatus.value == status) return;
    _streamingAssistantStatus.value = status;
  }

  String _assistantStatusForTrace(
    LlmTraceEvent event,
    _AiStrings strings,
  ) {
    switch (event.kind) {
      case 'reasoning':
        return strings.assistantThinking;
      case 'tool_request':
        return strings.assistantRunningTool(_traceToolName(event.title));
      case 'tool_result':
        return strings.assistantProcessingToolResult;
      case 'approval':
        return strings.assistantProcessingApproval;
      case 'multi_agent':
        return strings.assistantCollaborating;
      case 'budget':
        final lowerTitle = event.title.toLowerCase();
        if (lowerTitle.contains('running')) {
          return strings.assistantToolBudgetAudit;
        }
        if (lowerTitle.contains('rejected')) {
          return strings.assistantToolBudgetStopped;
        }
        return strings.assistantToolBudgetExtended;
      default:
        return strings.assistantPreparing;
    }
  }

  String _traceToolName(String title) {
    final index = title.indexOf(':');
    if (index < 0 || index == title.length - 1) return title;
    return title.substring(index + 1).trim();
  }

  void _clearStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
  }) {
    final target = _streamingAssistantTarget;
    if (target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != assistantCreatedAt) {
      return;
    }
    _streamingAssistantTarget = null;
    _streamingAssistantText.value = '';
    _streamingAssistantStatus.value = '';
  }

  void _scrollToBottom({bool jump = false}) {
    _pendingScrollJump = _pendingScrollJump || jump;
    if (_scrollToBottomScheduled) return;
    _scrollToBottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottomScheduled = false;
      final shouldJump = _pendingScrollJump;
      _pendingScrollJump = false;
      if (!_scrollController.hasClients) return;
      if (!shouldJump && _sending && !_isUserAtBottom) return;
      if (shouldJump || _sending) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        _setUserAtBottom(true);
        return;
      }
      _setUserAtBottom(true);
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  List<AiTodoStep> _parseTodoStepsFromText(String text) {
    try {
      final reg = RegExp(r'```playbook\s*(\{[\s\S]*?\})\s*```');
      final match = reg.firstMatch(text);
      if (match == null) return const [];
      final rawJson = match.group(1);
      if (rawJson == null) return const [];
      final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
      final stepsList = decoded['steps'] as List? ?? [];
      final now = DateTime.now();
      return stepsList.asMap().entries.map((entry) {
        final idx = entry.key;
        final item = entry.value;
        final stepName = item['name']?.toString() ?? 'Step ${idx + 1}';
        final command = item['command']?.toString() ?? '';
        final desc = item['description']?.toString() ?? '';
        return AiTodoStep(
          id: 'todo-${now.millisecondsSinceEpoch}-$idx',
          name: stepName,
          command: command,
          description: desc,
          status: StepStatus.pending,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _runTodoStep({
    required String chatId,
    required AiChatMessageRecord message,
    required int stepIndex,
  }) async {
    final activeChat = _chatById(chatId);
    if (activeChat == null) return;

    final msgIndex =
        activeChat.messages.indexWhere((m) => m.createdAt == message.createdAt);
    if (msgIndex < 0) return;
    final latestMsg = activeChat.messages[msgIndex];

    final steps = [...latestMsg.todoSteps];
    if (stepIndex < 0 || stepIndex >= steps.length) return;

    final targetStep = steps[stepIndex];
    if (targetStep.status == StepStatus.running ||
        targetStep.status == StepStatus.success) {
      return;
    }

    if (_selectedConnectionIds.isEmpty) {
      final isEn = context.read<AppSettings>().language == AppLanguage.en;
      _showCommandFeedback(
        isEn
            ? 'Please select a target server in the tools bar first.'
            : '请先在工具条中选择要执行的目标服务器。',
        context,
      );
      return;
    }
    final connectionId = _selectedConnectionIds.first;

    steps[stepIndex] = targetStep.copyWith(status: StepStatus.running);
    final nextMsg = latestMsg.copyWith(todoSteps: steps);

    final updatedMessages = [...activeChat.messages];
    updatedMessages[msgIndex] = nextMsg;
    final updatedChat = activeChat.copyWith(
      messages: updatedMessages,
      updatedAt: DateTime.now(),
    );

    setState(() {
      _replaceChat(updatedChat);
    });
    final storage = context.read<StorageService>();
    final ssh = context.read<SshService>();
    unawaited(storage.saveAiChat(updatedChat));

    final timeoutSeconds = await storage.getAiRequestTimeoutSeconds();

    StepStatus finalStatus = StepStatus.success;
    String? stdout;
    String? stderr;
    int? exitCode;

    try {
      final res = await ssh.runOneShotCommand(
        connectionId: connectionId,
        command: targetStep.command,
        timeout: Duration(seconds: timeoutSeconds),
      );
      stdout = res.stdout;
      stderr = res.stderr;
      exitCode = res.exitCode;
      if (exitCode != 0) {
        finalStatus = StepStatus.failed;
      }
    } catch (e) {
      finalStatus = StepStatus.failed;
      stderr = e.toString();
    }

    final currentChat = _chatById(chatId) ?? updatedChat;
    final finalMessages = [...currentChat.messages];
    final targetIndex =
        finalMessages.indexWhere((m) => m.createdAt == message.createdAt);
    if (targetIndex >= 0) {
      final currentMsg = finalMessages[targetIndex];
      final nextSteps = [...currentMsg.todoSteps];
      if (stepIndex >= 0 && stepIndex < nextSteps.length) {
        nextSteps[stepIndex] = targetStep.copyWith(
          status: finalStatus,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
        );
        final finalMsg = currentMsg.copyWith(todoSteps: nextSteps);
        finalMessages[targetIndex] = finalMsg;
      }
    }

    final finalChat = currentChat.copyWith(
      messages: finalMessages,
      updatedAt: DateTime.now(),
    );

    setState(() {
      _replaceChat(finalChat);
    });
    unawaited(storage.saveAiChat(finalChat));
  }
}
