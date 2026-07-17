part of 'ai_chat_viewmodel.dart';

extension AiChatHistoryActions on AiChatViewModel {
  Future<void> loadInitialDraft() async {
    if (_settingsLoadStarted) return;
    _settingsLoadStarted = true;
    _loading = true;
    _initialDraftFailed = false;
    notify();
    try {
      final settings = await _storageService.loadAiConnectionSettings();
      final draft = _newChatRecord(settings.model);
      _chats = [draft];
      _activeChatId = draft.id;
      _contextWindowTokens = settings.contextWindowTokens;
    } catch (error, stackTrace) {
      _initialDraftFailed = true;
      AppLogService.instance.error(
        'Failed to initialize AI chat',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _loading = false;
      notify();
    }
  }

  Future<void> retryInitialDraft() async {
    if (_loading || (!_initialDraftFailed && activeChat != null)) return;
    _settingsLoadStarted = false;
    await loadInitialDraft();
  }

  // 加载历史记录
  Future<void> loadHistoryChatsIfNeeded() async {
    if (_historyLoadStarted || _historyLoading) return;
    _historyLoading = true;
    notify();
    try {
      final chats = (await _storageService.loadAiChats())
          .where((chat) => !_deletedChatIds.contains(chat.id))
          .toList();
      _historyLoadStarted = true;
      final currentChats = List<AiChatRecord>.from(_chats);
      final currentById = {for (final chat in currentChats) chat.id: chat};
      final mergedHistory = <AiChatRecord>[];
      final mergedIds = <String>{};
      for (final storedChat in chats) {
        final current = currentById[storedChat.id];
        mergedHistory.add(
          current != null && current.messages.isNotEmpty ? current : storedChat,
        );
        mergedIds.add(storedChat.id);
      }
      for (final current in currentChats) {
        if (current.messages.isNotEmpty && mergedIds.add(current.id)) {
          mergedHistory.add(current);
        }
      }
      mergedHistory.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _savedHistoryChats = mergedHistory;

      final drafts = currentChats
          .where((chat) => chat.messages.isEmpty)
          .toList();
      final draftIds = drafts.map((chat) => chat.id).toSet();
      _chats = [
        ...drafts,
        ...mergedHistory.where((chat) => !draftIds.contains(chat.id)),
      ];
      _activeChatId ??= _chats.isEmpty ? null : _chats.first.id;
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'Failed to load AI chat history',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _historyLoading = false;
      notify();
    }
  }

  // 创建/切换/删除会话
  Future<String> loadNewChatModel() async =>
      (await _storageService.loadAiConnectionSettings()).model;

  bool createChat(
    String model, {
    Set<String> preserveChatIds = const <String>{},
  }) {
    if (_chatMutationLocked) return false;
    final chat = _newChatRecord(model);
    _chats = [
      chat,
      ..._chats.where(
        (item) => item.messages.isNotEmpty || preserveChatIds.contains(item.id),
      ),
    ];
    _activeChatId = chat.id;
    notify();
    _triggerScroll();
    return true;
  }

  void selectChat(String id) {
    if (_chatMutationLocked) return;
    if (_activeChatId == id) return;
    _activeChatId = id;
    notify();
    _triggerScroll();
  }

  Future<void> deleteChat(String id) async {
    if (!_tryBeginChatStateWrite(
      allowDuringGeneration: true,
      allowDuringPlanApproval: true,
    )) {
      return;
    }
    try {
      if (_chats.isEmpty && _savedHistoryChats.isEmpty) return;
      if (_activeGenerationChatId == id) {
        _deletedGenerationChatIds.add(id);
        _activeCancellationToken?.cancel();
        final pending = _pendingApproval;
        if (pending?.chatId == id && !pending!.completer.isCompleted) {
          pending.completer.complete(
            const AiToolApprovalDecision.rejected(abort: true),
          );
          _pendingApproval = null;
        }
      }
      final deleted = _chatById(id);
      if (deleted != null) _deletedChatIds.add(id);
      _chatAllowedTools.remove(id);
      _pendingForceCompressionChats.remove(id);
      final nextChats = _chats.where((chat) => chat.id != id).toList();
      if (nextChats.isEmpty) {
        final settings = await _storageService.loadAiConnectionSettings();
        nextChats.add(_newChatRecord(settings.model));
      }
      _chats = nextChats;
      _savedHistoryChats = _savedHistoryChats
          .where((chat) => chat.id != id)
          .toList();
      if (_activeChatId == id || _activeChatId == null) {
        _activeChatId = nextChats.first.id;
      }
      notify();
      if (deleted?.messages.isNotEmpty == true) {
        await _storageService.deleteAiChat(id);
      }
      ClientWebViewService.instance.clearSession(id);
      _triggerScroll();
    } finally {
      _endChatStateWrite();
    }
  }

  Future<bool> updateActiveChat(AiChatRecord chat) async {
    if (chat.id != _activeChatId || !_tryBeginChatStateWrite()) return false;
    try {
      await _storageService.saveAiChat(chat);
      _replaceChat(chat, activate: false);
      notify();
      return true;
    } finally {
      _endChatStateWrite();
    }
  }

  Future<SetPlanModeResult> setPlanModeForActiveChat({
    required String chatId,
    required bool enabled,
  }) async {
    if (_sending || _planApprovalInFlight || _chatMutationLocked) {
      return SetPlanModeResult.busy;
    }
    final chat = activeChat;
    if (chat == null || chat.id != chatId || _activeChatId != chatId) {
      return SetPlanModeResult.targetChanged;
    }
    if (chat.planMode == enabled && (!enabled || chat.approvedPlan == null)) {
      return SetPlanModeResult.unchanged;
    }

    final updated = chat.copyWith(
      planMode: enabled,
      updatedAt: DateTime.now(),
      clearApprovedPlan: enabled,
    );
    try {
      final saved = await updateActiveChat(updated);
      return saved ? SetPlanModeResult.updated : SetPlanModeResult.busy;
    } catch (_, stackTrace) {
      AppLogService.instance.error(
        'Plan Mode update failed',
        details: 'chatId=$chatId enabled=$enabled',
        stackTrace: stackTrace,
      );
      return SetPlanModeResult.failed;
    }
  }

  // 附件操作
  void addAttachment(AiChatAttachment attachment) {
    _pendingAttachments.add(attachment);
    notify();
  }

  void removeAttachmentAt(int index) {
    if (index >= 0 && index < _pendingAttachments.length) {
      _pendingAttachments.removeAt(index);
      notify();
    }
  }

  void clearAttachments() {
    _pendingAttachments.clear();
    notify();
  }

  // 选择服务器连接
  void updateSelectedConnections(Set<String> connectionIds) {
    _selectedConnectionIds.clear();
    _selectedConnectionIds.addAll(connectionIds);
    notify();
  }

  ConnectionConfig? getConnection(String id) {
    return _storageService.getConnection(id);
  }

  List<ConnectionConfig> get connections => _storageService.connections;

  String? checkPendingDiagnosticPrompt() {
    final prompt = _playbookService.pendingDiagnosticPrompt;
    if (prompt != null) {
      _playbookService.pendingDiagnosticPrompt = null;
    }
    return prompt;
  }

  Future<Map<String, dynamic>> loadLlmSettingsData() async {
    final settings = await _storageService.loadAiConnectionSettings();
    final cachedModels = await _storageService.loadCachedAiModels(
      baseUrl: settings.baseUrl,
    );
    final baseUrlHistory = await _storageService.loadAiBaseUrlHistory();
    final apiKeyHistory = await _storageService.loadAiApiKeyHistory();
    return {
      'settings': settings,
      'cachedModels': cachedModels,
      'baseUrlHistory': baseUrlHistory,
      'apiKeyHistory': apiKeyHistory,
    };
  }

  void logLlmSettingsOpened(AiConnectionSettings settings) {
    AppLogService.instance.info(
      'LLM settings page opened',
      details:
          'hasBaseUrl=${settings.baseUrl.trim().isNotEmpty} modelConfigured=${settings.model.trim().isNotEmpty} hasApiKey=${settings.hasApiKey}',
    );
  }

  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    return await _storageService.loadAiConnectionSettings();
  }

  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    String? helperModel,
    String? auditModel,
    String? modelFallbackPolicy,
    int? contextWindowTokens,
    int? timeoutSeconds,
    bool? deepSeekThinkingEnabled,
    String? deepSeekReasoningEffort,
    String? openAiReasoningEffort,
    bool? webSearchEnabled,
    int? webSearchMaxResults,
    String? webSearchEngine,
    bool? multiAgentEnabled,
    int? multiAgentMaxAgents,
    bool? postToolReviewEnabled,
    int? toolCallBudget,
    String? agentLoopMode,
    int? maxImageSizeBytes,
    int? maxFileSizeBytes,
    String? apiKey,
    String? selectedApiKeyId,
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    LlmApiFormat? apiFormat,
  }) async {
    try {
      await _storageService.saveAiConnectionSettings(
        baseUrl: baseUrl,
        model: model,
        helperModel: helperModel,
        auditModel: auditModel,
        modelFallbackPolicy: modelFallbackPolicy,
        contextWindowTokens: contextWindowTokens,
        timeoutSeconds: timeoutSeconds,
        deepSeekThinkingEnabled: deepSeekThinkingEnabled,
        deepSeekReasoningEffort: deepSeekReasoningEffort,
        openAiReasoningEffort: openAiReasoningEffort,
        webSearchEnabled: webSearchEnabled,
        webSearchMaxResults: webSearchMaxResults,
        webSearchEngine: webSearchEngine,
        multiAgentEnabled: multiAgentEnabled,
        multiAgentMaxAgents: multiAgentMaxAgents,
        postToolReviewEnabled: postToolReviewEnabled,
        toolCallBudget: toolCallBudget,
        agentLoopMode: agentLoopMode,
        maxImageSizeBytes: maxImageSizeBytes,
        maxFileSizeBytes: maxFileSizeBytes,
        apiKey: apiKey,
        selectedApiKeyId: selectedApiKeyId,
        clearApiKey: clearApiKey,
        quarkSearchEndpoint: quarkSearchEndpoint,
        quarkApiKey: quarkApiKey,
        clearQuarkApiKey: clearQuarkApiKey,
        useCustomPrompts: useCustomPrompts,
        customSystemPrompt: customSystemPrompt,
        customPlannerPrompt: customPlannerPrompt,
        customOperatorPrompt: customOperatorPrompt,
        customExplorePrompt: customExplorePrompt,
        customReviewerPrompt: customReviewerPrompt,
        customSummarizerPrompt: customSummarizerPrompt,
        customCoordinatorPrompt: customCoordinatorPrompt,
        apiFormat: apiFormat,
      );
      notify();
    } catch (_, stackTrace) {
      AppLogService.instance.error(
        'LLM settings save failed',
        stackTrace: stackTrace,
        details:
            'hasBaseUrl=${baseUrl.trim().isNotEmpty} modelConfigured=${model.trim().isNotEmpty} hasApiKeyInput=${apiKey?.trim().isNotEmpty == true} selectedApiKey=${selectedApiKeyId?.trim().isNotEmpty == true}',
      );
      rethrow;
    }
  }

  Future<List<String>> loadCachedAiModels({String? baseUrl}) async {
    return await _storageService.loadCachedAiModels(baseUrl: baseUrl);
  }

  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) async {
    await _storageService.removeAiBaseUrlHistoryEntry(baseUrl);
  }

  Future<void> removeAiApiKeyHistoryEntry(String id) async {
    await _storageService.removeAiApiKeyHistoryEntry(id);
  }

  Future<List<AiApiKeyHistoryEntry>> loadAiApiKeyHistory() async {
    return await _storageService.loadAiApiKeyHistory();
  }

  Future<String?> getAiApiKeyById(String id) async {
    return await _storageService.getAiApiKeyById(id);
  }

  Future<String?> getAliyunApiKey() async {
    return await _storageService.getAliyunApiKey();
  }

  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  }) async {
    await _storageService.saveCachedAiModels(baseUrl: baseUrl, models: models);
  }

  Future<List<String>> fetchModelsFromProvider({
    required String baseUrl,
    required String? typedApiKey,
    required String? selectedApiKeyId,
    required List<String> fallbackModels,
  }) async {
    final settings = await _storageService.loadAiConnectionSettings();
    final resolvedApiKey = typedApiKey?.trim().isNotEmpty == true
        ? typedApiKey!.trim()
        : (selectedApiKeyId == null
              ? null
              : await _storageService.getAiApiKeyById(selectedApiKeyId));

    final service = _runtimeFactory.createLlmChatService(
      settings: settings,
      model: settings.model,
      chatId: _activeChatId ?? '',
      language: _appSettings.language,
    );

    final fetched = await service.fetchModels(
      baseUrl: baseUrl.trim(),
      apiKey: resolvedApiKey,
    );

    final resolvedModels = AiChatViewModel.resolveFetchedModelOptions(
      fetchedModels: fetched,
      fallbackModels: fallbackModels,
    );

    await _storageService.saveCachedAiModels(
      baseUrl: baseUrl.trim(),
      models: resolvedModels,
    );

    return resolvedModels;
  }

  void updateAllowedTools(String chatId, Set<String> allowedTools) {
    _chatAllowedTools[chatId] = Set<String>.from(allowedTools);
    notify();
  }
}
