part of '../llm_chat_screen.dart';

class LlmSettingsScreen extends StatefulWidget {
  final AiConnectionSettings initialSettings;
  final List<String> initialModels;
  final List<String> initialBaseUrlHistory;
  final List<AiApiKeyHistoryEntry> initialApiKeyHistory;

  const LlmSettingsScreen({
    super.key,
    required this.initialSettings,
    required this.initialModels,
    required this.initialBaseUrlHistory,
    required this.initialApiKeyHistory,
  });

  @override
  State<LlmSettingsScreen> createState() => _LlmSettingsScreenState();
}

class _LlmSettingsScreenState extends State<LlmSettingsScreen> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _helperModelController;
  late final TextEditingController _auditModelController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _quarkApiKeyController;
  late final TextEditingController _quarkEndpointController;
  late List<String> _baseUrlHistory;
  late List<AiApiKeyHistoryEntry> _apiKeyHistory;
  late List<String> _models;
  late int _contextWindowTokens;
  late int _timeoutSeconds;
  late bool _deepSeekThinkingEnabled;
  late String _deepSeekReasoningEffort;
  late String _openAiReasoningEffort;
  late bool _webSearchEnabled;
  late int _webSearchMaxResults;
  late String _webSearchEngine;
  late bool _ragEnabled;
  late String _ragSearchMode;
  late bool _multiAgentEnabled;
  late int _multiAgentMaxAgents;
  late bool _postToolReviewEnabled;
  late String _modelFallbackPolicy;
  late int _toolCallBudget;
  late String _agentLoopMode;
  late int _maxImageSizeBytes;
  late int _maxFileSizeBytes;
  String? _selectedApiKeyId;
  late LlmApiFormat _apiFormat;
  bool _loadingModels = false;
  bool _showUnsupportedFormatWarning = false;
  bool _saving = false;
  bool _discardDialogOpen = false;
  String? _errorText;

  late bool _initialRagEnabled;
  late String _initialRagSearchMode;
  late LlmApiFormat _initialApiFormat;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController(
      text: widget.initialSettings.baseUrl,
    );
    _modelController = TextEditingController(
      text: widget.initialSettings.model,
    );
    _helperModelController = TextEditingController(
      text: widget.initialSettings.helperModel,
    );
    _auditModelController = TextEditingController(
      text: widget.initialSettings.auditModel,
    );
    _apiKeyController = TextEditingController();
    _quarkApiKeyController = TextEditingController();
    _quarkEndpointController = TextEditingController(
      text: widget.initialSettings.quarkSearchEndpoint,
    );
    _baseUrlHistory = List<String>.from(widget.initialBaseUrlHistory);
    _apiKeyHistory = List<AiApiKeyHistoryEntry>.from(
      widget.initialApiKeyHistory,
    );
    _models = List<String>.from(widget.initialModels);
    _contextWindowTokens = widget.initialSettings.contextWindowTokens;
    _timeoutSeconds = widget.initialSettings.timeoutSeconds;
    _deepSeekThinkingEnabled = widget.initialSettings.deepSeekThinkingEnabled;
    _deepSeekReasoningEffort = widget.initialSettings.deepSeekReasoningEffort;
    _openAiReasoningEffort = widget.initialSettings.openAiReasoningEffort;
    _webSearchEnabled = widget.initialSettings.webSearchEnabled;
    _webSearchMaxResults = widget.initialSettings.webSearchMaxResults;
    _webSearchEngine = widget.initialSettings.webSearchEngine;
    _initialRagEnabled = context.read<AppSettings>().ragEnabled;
    _initialRagSearchMode = context.read<AppSettings>().ragSearchMode;
    _ragEnabled = _initialRagEnabled;
    _ragSearchMode = _initialRagSearchMode;
    _multiAgentEnabled = widget.initialSettings.multiAgentEnabled;
    _multiAgentMaxAgents = widget.initialSettings.multiAgentMaxAgents;
    _postToolReviewEnabled = widget.initialSettings.postToolReviewEnabled;
    _modelFallbackPolicy = widget.initialSettings.modelFallbackPolicy;
    _toolCallBudget = widget.initialSettings.toolCallBudget;
    _agentLoopMode = AiAgentLoopMode.normalize(
      widget.initialSettings.agentLoopMode,
    );
    _maxImageSizeBytes = widget.initialSettings.maxImageSizeBytes;
    _maxFileSizeBytes = widget.initialSettings.maxFileSizeBytes;
    _selectedApiKeyId = widget.initialSettings.activeApiKeyId;
    const supportedApiFormats = [
      LlmApiFormat.openAiChatCompletions,
      LlmApiFormat.geminiOpenAiCompatible,
      LlmApiFormat.anthropicMessages,
    ];
    final originalFormat = widget.initialSettings.apiFormat;
    if (!supportedApiFormats.contains(originalFormat)) {
      _apiFormat = LlmApiFormat.openAiChatCompletions;
      _showUnsupportedFormatWarning = true;
    } else {
      _apiFormat = originalFormat;
    }
    _initialApiFormat = _apiFormat;

    _baseUrlController.addListener(_onTextChanged);
    _modelController.addListener(_onTextChanged);
    _helperModelController.addListener(_onTextChanged);
    _auditModelController.addListener(_onTextChanged);
    _apiKeyController.addListener(_onTextChanged);
    _quarkApiKeyController.addListener(_onTextChanged);
    _quarkEndpointController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _baseUrlController.removeListener(_onTextChanged);
    _modelController.removeListener(_onTextChanged);
    _helperModelController.removeListener(_onTextChanged);
    _auditModelController.removeListener(_onTextChanged);
    _apiKeyController.removeListener(_onTextChanged);
    _quarkApiKeyController.removeListener(_onTextChanged);
    _quarkEndpointController.removeListener(_onTextChanged);

    _baseUrlController.dispose();
    _modelController.dispose();
    _helperModelController.dispose();
    _auditModelController.dispose();
    _apiKeyController.dispose();
    _quarkApiKeyController.dispose();
    _quarkEndpointController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
  }

  bool _hasChanges() {
    final initial = widget.initialSettings;
    return _baseUrlController.text != initial.baseUrl ||
        _modelController.text != initial.model ||
        _helperModelController.text != initial.helperModel ||
        _auditModelController.text != initial.auditModel ||
        _apiKeyController.text.isNotEmpty ||
        _quarkApiKeyController.text.isNotEmpty ||
        _quarkEndpointController.text != initial.quarkSearchEndpoint ||
        _contextWindowTokens != initial.contextWindowTokens ||
        _timeoutSeconds != initial.timeoutSeconds ||
        _deepSeekThinkingEnabled != initial.deepSeekThinkingEnabled ||
        _deepSeekReasoningEffort != initial.deepSeekReasoningEffort ||
        _openAiReasoningEffort != initial.openAiReasoningEffort ||
        _webSearchEnabled != initial.webSearchEnabled ||
        _webSearchMaxResults != initial.webSearchMaxResults ||
        _webSearchEngine != initial.webSearchEngine ||
        _ragEnabled != _initialRagEnabled ||
        _ragSearchMode != _initialRagSearchMode ||
        _multiAgentEnabled != initial.multiAgentEnabled ||
        _multiAgentMaxAgents != initial.multiAgentMaxAgents ||
        _postToolReviewEnabled != initial.postToolReviewEnabled ||
        _modelFallbackPolicy != initial.modelFallbackPolicy ||
        _toolCallBudget != initial.toolCallBudget ||
        _agentLoopMode != AiAgentLoopMode.normalize(initial.agentLoopMode) ||
        _maxImageSizeBytes != initial.maxImageSizeBytes ||
        _maxFileSizeBytes != initial.maxFileSizeBytes ||
        _selectedApiKeyId != initial.activeApiKeyId ||
        _apiFormat != _initialApiFormat;
  }

  Future<void> _requestClose(AiStrings strings) async {
    if (_saving || _discardDialogOpen) return;
    if (!_hasChanges()) {
      Navigator.maybePop(context);
      return;
    }

    _discardDialogOpen = true;
    final discard = await DestructiveConfirmDialog.show(
      context,
      title: strings.discardSettingsTitle,
      content: strings.discardSettingsContent,
      cancelLabel: strings.cancel,
      confirmLabel: strings.discardChanges,
    );
    _discardDialogOpen = false;
    if (discard && mounted) Navigator.pop(context);
  }

  void _showErrorMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String? get _selectedApiKeyMasked {
    for (final entry in _apiKeyHistory) {
      if (entry.id == _selectedApiKeyId) {
        return entry.maskedValue;
      }
    }
    return null;
  }

  bool get _showsDeepSeekControls => isDeepSeekModelId(_modelController.text);

  bool get _showsOpenAiReasoningControls =>
      supportsOpenAiReasoningEffort(_modelController.text);

  Future<void> _applyBaseUrlSelection(String baseUrl) async {
    final viewModel = context.read<AiChatViewModel>();
    _baseUrlController.text = baseUrl;
    final cachedModels = await viewModel.loadCachedAiModels(baseUrl: baseUrl);
    if (!mounted) return;
    setState(() {
      _models = buildInitialModelOptions(
        currentModel: _modelController.text,
        cachedModels: cachedModels,
      );
      if (_models.isNotEmpty && !_models.contains(_modelController.text)) {
        _modelController.text = _models.first;
      }
    });
  }

  void _selectApiKeyHistoryEntry(String id) {
    if (!_apiKeyHistory.any((entry) => entry.id == id)) return;
    setState(() {
      _selectedApiKeyId = id;
      _apiKeyController.clear();
      _apiKeyHistory = [
        for (final entry in _apiKeyHistory)
          AiApiKeyHistoryEntry(
            id: entry.id,
            maskedValue: entry.maskedValue,
            isSelected: entry.id == id,
          ),
      ];
    });
  }

  Future<void> _deleteBaseUrlHistoryEntry(String baseUrl) async {
    final viewModel = context.read<AiChatViewModel>();
    await viewModel.removeAiBaseUrlHistoryEntry(baseUrl);
    if (!mounted) return;
    setState(() {
      _baseUrlHistory = _baseUrlHistory
          .where((item) => item != baseUrl)
          .toList();
    });
  }

  Future<void> _deleteApiKeyHistoryEntry(String id) async {
    final viewModel = context.read<AiChatViewModel>();
    await viewModel.removeAiApiKeyHistoryEntry(id);
    final refreshed = await viewModel.loadAiApiKeyHistory();
    if (!mounted) return;
    final preferredSelectedId = _selectedApiKeyId;
    String? nextSelectedId = preferredSelectedId;
    if (nextSelectedId != null &&
        !refreshed.any((entry) => entry.id == nextSelectedId)) {
      nextSelectedId = null;
    }
    if (nextSelectedId == null) {
      for (final entry in refreshed) {
        if (entry.isSelected) {
          nextSelectedId = entry.id;
          break;
        }
      }
    }
    setState(() {
      _apiKeyHistory = [
        for (final entry in refreshed)
          AiApiKeyHistoryEntry(
            id: entry.id,
            maskedValue: entry.maskedValue,
            isSelected: entry.id == nextSelectedId,
          ),
      ];
      _selectedApiKeyId = nextSelectedId;
    });
  }

  Future<void> _openBaseUrlHistory(AiStrings strings) async {
    final action = await showModalBottomSheet<_SettingsHistoryAction<String>>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: HistoryActionSheet<String>(
          title: strings.baseUrlHistory,
          emptyText: strings.noBaseUrlHistory,
          deleteTooltip: strings.delete,
          items: _baseUrlHistory,
          labelBuilder: (value) => value,
          onSelect: (value) =>
              Navigator.pop(sheetContext, _SettingsHistoryAction.select(value)),
          onDelete: (value) =>
              Navigator.pop(sheetContext, _SettingsHistoryAction.delete(value)),
        ),
      ),
    );
    if (action == null) return;
    if (!mounted) return;
    if (action.delete) {
      final confirmed = await DestructiveConfirmDialog.show(
        context,
        title: strings.deleteBaseUrlHistoryTitle,
        content: strings.deleteBaseUrlHistoryContent(action.value),
        cancelLabel: strings.cancel,
        confirmLabel: strings.delete,
      );
      if (confirmed) {
        await _deleteBaseUrlHistoryEntry(action.value);
      }
      return;
    }
    await _applyBaseUrlSelection(action.value);
  }

  Future<void> _openApiKeyHistory(AiStrings strings) async {
    final action =
        await showModalBottomSheet<
          _SettingsHistoryAction<AiApiKeyHistoryEntry>
        >(
          context: context,
          showDragHandle: true,
          builder: (sheetContext) => SafeArea(
            child: HistoryActionSheet<AiApiKeyHistoryEntry>(
              title: strings.apiKeyHistory,
              emptyText: strings.noApiKeyHistory,
              deleteTooltip: strings.delete,
              items: _apiKeyHistory,
              labelBuilder: (entry) => entry.maskedValue,
              selectedValue: _selectedApiKeyId,
              valueKeyBuilder: (entry) => entry.id,
              onSelect: (entry) => Navigator.pop(
                sheetContext,
                _SettingsHistoryAction.select(entry),
              ),
              onDelete: (entry) => Navigator.pop(
                sheetContext,
                _SettingsHistoryAction.delete(entry),
              ),
            ),
          ),
        );
    if (action == null) return;
    if (!mounted) return;
    if (action.delete) {
      final confirmed = await DestructiveConfirmDialog.show(
        context,
        title: strings.deleteApiKeyHistoryTitle,
        content: strings.deleteApiKeyHistoryContent(action.value.maskedValue),
        cancelLabel: strings.cancel,
        confirmLabel: strings.delete,
      );
      if (confirmed) {
        await _deleteApiKeyHistoryEntry(action.value.id);
      }
      return;
    }
    _selectApiKeyHistoryEntry(action.value.id);
  }

  Future<void> _refreshModels(AiStrings strings) async {
    final viewModel = context.read<AiChatViewModel>();
    setState(() {
      _loadingModels = true;
      _errorText = null;
    });
    try {
      final typedApiKey = _apiKeyController.text.trim();
      final resolvedModels = await viewModel.fetchModelsFromProvider(
        baseUrl: _baseUrlController.text.trim(),
        typedApiKey: typedApiKey.isNotEmpty ? typedApiKey : null,
        selectedApiKeyId: _selectedApiKeyId,
        fallbackModels: _models,
      );
      if (!mounted) return;
      setState(() {
        _models = resolvedModels;
        _loadingModels = false;
        if (_models.isNotEmpty && !_models.contains(_modelController.text)) {
          _modelController.text = _models.first;
        }
      });
    } catch (e) {
      if (!mounted) return;
      final message = strings.modelsFailed(e.toString());
      setState(() {
        _loadingModels = false;
        _errorText = message;
      });
      _showErrorMessage(message);
    }
  }

  Future<void> _save(AiStrings strings) async {
    FocusScope.of(context).unfocus();
    final viewModel = context.read<AiChatViewModel>();
    final appSettings = context.read<AppSettings>();
    final pending = _PendingAiSettings(
      baseUrl: _baseUrlController.text,
      model: _modelController.text,
      helperModel: _helperModelController.text,
      auditModel: _auditModelController.text,
      modelFallbackPolicy: _modelFallbackPolicy,
      contextWindowTokens: _contextWindowTokens,
      timeoutSeconds: _timeoutSeconds,
      deepSeekThinkingEnabled: _deepSeekThinkingEnabled,
      deepSeekReasoningEffort: _deepSeekReasoningEffort,
      openAiReasoningEffort: _openAiReasoningEffort,
      webSearchEnabled: _webSearchEnabled,
      webSearchMaxResults: _webSearchMaxResults,
      webSearchEngine: _webSearchEngine,
      quarkSearchEndpoint: _quarkEndpointController.text,
      quarkApiKey: _quarkApiKeyController.text,
      multiAgentEnabled: _multiAgentEnabled,
      multiAgentMaxAgents: _multiAgentMaxAgents,
      postToolReviewEnabled: _postToolReviewEnabled,
      toolCallBudget: _toolCallBudget,
      agentLoopMode: _agentLoopMode,
      maxImageSizeBytes: _maxImageSizeBytes,
      maxFileSizeBytes: _maxFileSizeBytes,
      apiKey: _apiKeyController.text,
      selectedApiKeyId: _selectedApiKeyId,
      apiFormat: _apiFormat,
    );
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      await viewModel.saveAiConnectionSettings(
        baseUrl: pending.baseUrl,
        model: pending.model,
        helperModel: pending.helperModel,
        auditModel: pending.auditModel,
        modelFallbackPolicy: pending.modelFallbackPolicy,
        contextWindowTokens: pending.contextWindowTokens,
        timeoutSeconds: pending.timeoutSeconds,
        deepSeekThinkingEnabled: pending.deepSeekThinkingEnabled,
        deepSeekReasoningEffort: pending.deepSeekReasoningEffort,
        openAiReasoningEffort: pending.openAiReasoningEffort,
        webSearchEnabled: pending.webSearchEnabled,
        webSearchMaxResults: pending.webSearchMaxResults,
        webSearchEngine: pending.webSearchEngine,
        quarkSearchEndpoint: pending.quarkSearchEndpoint,
        quarkApiKey: pending.quarkApiKey,
        multiAgentEnabled: pending.multiAgentEnabled,
        multiAgentMaxAgents: pending.multiAgentMaxAgents,
        postToolReviewEnabled: pending.postToolReviewEnabled,
        toolCallBudget: pending.toolCallBudget,
        agentLoopMode: pending.agentLoopMode,
        maxImageSizeBytes: pending.maxImageSizeBytes,
        maxFileSizeBytes: pending.maxFileSizeBytes,
        apiKey: pending.apiKey,
        selectedApiKeyId: pending.selectedApiKeyId,
        apiFormat: pending.apiFormat,
      );
      if (mounted) {
        await appSettings.setRagEnabled(_ragEnabled);
        await appSettings.setRagSearchMode(_ragSearchMode);
      }
      if (!mounted) return;
      Navigator.pop(context, pending);
    } catch (e) {
      if (!mounted) return;
      final message = strings.failed(e);
      setState(() {
        _saving = false;
        _errorText = message;
      });
      _showErrorMessage(message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);
    if (_showUnsupportedFormatWarning) {
      _showUnsupportedFormatWarning = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(strings.apiFormatUnsupported),
            duration: const Duration(seconds: 4),
          ),
        );
      });
    }
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !_saving && !_hasChanges(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestClose(strings));
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const ValueKey<String>('llm-settings-close'),
            tooltip: strings.close,
            onPressed: _saving ? null : () => _requestClose(strings),
            icon: const Icon(Icons.close_rounded),
          ),
          title: Text(strings.settings),
          actions: _hasChanges()
              ? [
                  TextButton(
                    onPressed: _saving ? null : () => _requestClose(strings),
                    child: Text(strings.cancel),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: FilledButton(
                      onPressed: _saving ? null : () => _save(strings),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(strings.save),
                    ),
                  ),
                ]
              : [
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: TextButton(
                      onPressed: () => _requestClose(strings),
                      child: Text(strings.close),
                    ),
                  ),
                ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: [
              if (_errorText != null) ...[
                DecoratedBox(
                  key: const ValueKey<String>('llm-settings-error'),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer.withValues(alpha: 0.36),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colorScheme.error.withValues(alpha: 0.42),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _errorText!,
                      style: TextStyle(color: colorScheme.error),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              _LlmApiConfigSection(
                strings: strings,
                saving: _saving,
                apiFormat: _apiFormat,
                onApiFormatChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _apiFormat = value;
                  });
                },
                baseUrlController: _baseUrlController,
                baseUrlHistory: _baseUrlHistory,
                onOpenBaseUrlHistory: () => _openBaseUrlHistory(strings),
                recommendedBaseUrl: _getRecommendedBaseUrl(_apiFormat),
                onUseRecommendedBaseUrl: () {
                  setState(() {
                    _baseUrlController.text = _getRecommendedBaseUrl(
                      _apiFormat,
                    );
                  });
                },
                apiKeyController: _apiKeyController,
                selectedApiKeyMasked: _selectedApiKeyMasked,
                apiKeyHistory: _apiKeyHistory,
                selectedApiKeyId: _selectedApiKeyId,
                onOpenApiKeyHistory: () => _openApiKeyHistory(strings),
                onSelectApiKeyHistoryEntry: _selectApiKeyHistoryEntry,
                models: _models,
                modelController: _modelController,
                loadingModels: _loadingModels,
                onRefreshModels: () => _refreshModels(strings),
                helperModelController: _helperModelController,
                auditModelController: _auditModelController,
                modelFallbackPolicy: _modelFallbackPolicy,
                onModelFallbackPolicyChanged: (value) {
                  if (value != null) {
                    setState(() => _modelFallbackPolicy = value);
                  }
                },
                contextWindowTokens: _contextWindowTokens,
                onContextWindowTokensChanged: (value) {
                  if (value != null) {
                    setState(() => _contextWindowTokens = value);
                  }
                },
                timeoutSeconds: _timeoutSeconds,
                onTimeoutSecondsChanged: (value) {
                  if (value != null) {
                    setState(() => _timeoutSeconds = value);
                  }
                },
              ),
              const SizedBox(height: 14),
              _LlmAgentConfigSection(
                strings: strings,
                saving: _saving,
                multiAgentEnabled: _multiAgentEnabled,
                onMultiAgentEnabledChanged: (value) {
                  setState(() => _multiAgentEnabled = value);
                },
                multiAgentMaxAgents: _multiAgentMaxAgents,
                onMultiAgentMaxAgentsChanged: (value) {
                  if (value != null) {
                    setState(() => _multiAgentMaxAgents = value);
                  }
                },
                postToolReviewEnabled: _postToolReviewEnabled,
                onPostToolReviewEnabledChanged: (value) {
                  setState(() => _postToolReviewEnabled = value);
                },
                toolCallBudget: _toolCallBudget,
                onToolCallBudgetChanged: (value) {
                  if (value != null) {
                    setState(() => _toolCallBudget = value);
                  }
                },
                agentLoopMode: _agentLoopMode,
                onAgentLoopModeChanged: (value) {
                  if (value != null) {
                    setState(
                      () => _agentLoopMode = AiAgentLoopMode.normalize(value),
                    );
                  }
                },
              ),
              const SizedBox(height: 14),
              _LlmReasoningConfigSection(
                strings: strings,
                saving: _saving,
                showsDeepSeekControls: _showsDeepSeekControls,
                deepSeekThinkingEnabled: _deepSeekThinkingEnabled,
                onDeepSeekThinkingChanged: (value) {
                  setState(() => _deepSeekThinkingEnabled = value);
                },
                deepSeekReasoningEffort: _deepSeekReasoningEffort,
                onDeepSeekReasoningEffortChanged: (value) {
                  if (value != null) {
                    setState(() => _deepSeekReasoningEffort = value);
                  }
                },
                showsOpenAiReasoningControls: _showsOpenAiReasoningControls,
                openAiReasoningEffort: _openAiReasoningEffort,
                onOpenAiReasoningEffortChanged: (value) {
                  if (value != null) {
                    setState(() => _openAiReasoningEffort = value);
                  }
                },
              ),
              const SizedBox(height: 14),
              _LlmSearchConfigSection(
                strings: strings,
                saving: _saving,
                webSearchEnabled: _webSearchEnabled,
                onWebSearchEnabledChanged: (value) {
                  setState(() => _webSearchEnabled = value);
                },
                webSearchEngine: _webSearchEngine,
                onWebSearchEngineChanged: (value) {
                  if (value != null) {
                    setState(() => _webSearchEngine = value);
                  }
                },
                hasQuarkApiKey: widget.initialSettings.hasQuarkApiKey,
                quarkApiKeyController: _quarkApiKeyController,
                quarkEndpointController: _quarkEndpointController,
                webSearchMaxResults: _webSearchMaxResults,
                onWebSearchMaxResultsChanged: (value) {
                  if (value != null) {
                    setState(() => _webSearchMaxResults = value);
                  }
                },
              ),
              const SizedBox(height: 14),
              _LlmRagConfigSection(
                strings: strings,
                saving: _saving,
                ragEnabled: _ragEnabled,
                onRagEnabledChanged: (value) {
                  setState(() => _ragEnabled = value);
                },
                ragSearchMode: _ragSearchMode,
                onRagSearchModeChanged: (value) {
                  if (value != null) {
                    setState(() => _ragSearchMode = value);
                  }
                },
                onManageRag: () {
                  Navigator.pushNamed(context, '/rag-knowledge');
                },
              ),
              const SizedBox(height: 14),
              _LlmUploadLimitsSection(
                strings: strings,
                saving: _saving,
                maxImageSizeBytes: _maxImageSizeBytes,
                onMaxImageSizeBytesChanged: (value) {
                  if (value != null) {
                    setState(() => _maxImageSizeBytes = value);
                  }
                },
                maxFileSizeBytes: _maxFileSizeBytes,
                onMaxFileSizeBytesChanged: (value) {
                  if (value != null) {
                    setState(() => _maxFileSizeBytes = value);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getRecommendedBaseUrl(LlmApiFormat format) {
    switch (format) {
      case LlmApiFormat.openAiChatCompletions:
        return 'https://api.deepseek.com';
      case LlmApiFormat.geminiOpenAiCompatible:
        return 'https://generativelanguage.googleapis.com/v1beta/openai';
      case LlmApiFormat.anthropicMessages:
        return 'https://api.anthropic.com';
      default:
        return 'https://api.deepseek.com';
    }
  }
}

class _SettingsHistoryAction<T> {
  final T value;
  final bool delete;

  const _SettingsHistoryAction._({required this.value, required this.delete});

  factory _SettingsHistoryAction.select(T value) {
    return _SettingsHistoryAction._(value: value, delete: false);
  }

  factory _SettingsHistoryAction.delete(T value) {
    return _SettingsHistoryAction._(value: value, delete: true);
  }
}

class _PendingAiSettings {
  final String baseUrl;
  final String model;
  final String helperModel;
  final String auditModel;
  final String modelFallbackPolicy;
  final int contextWindowTokens;
  final int timeoutSeconds;
  final bool deepSeekThinkingEnabled;
  final String deepSeekReasoningEffort;
  final String openAiReasoningEffort;
  final bool webSearchEnabled;
  final int webSearchMaxResults;
  final String webSearchEngine;
  final String quarkSearchEndpoint;
  final String quarkApiKey;
  final bool multiAgentEnabled;
  final int multiAgentMaxAgents;
  final bool postToolReviewEnabled;
  final int toolCallBudget;
  final String agentLoopMode;
  final int maxImageSizeBytes;
  final int maxFileSizeBytes;
  final String apiKey;
  final String? selectedApiKeyId;
  final LlmApiFormat apiFormat;

  const _PendingAiSettings({
    required this.baseUrl,
    required this.model,
    required this.helperModel,
    required this.auditModel,
    required this.modelFallbackPolicy,
    required this.contextWindowTokens,
    required this.timeoutSeconds,
    required this.deepSeekThinkingEnabled,
    required this.deepSeekReasoningEffort,
    required this.openAiReasoningEffort,
    required this.webSearchEnabled,
    required this.webSearchMaxResults,
    required this.webSearchEngine,
    required this.quarkSearchEndpoint,
    required this.quarkApiKey,
    required this.multiAgentEnabled,
    required this.multiAgentMaxAgents,
    required this.postToolReviewEnabled,
    required this.toolCallBudget,
    required this.agentLoopMode,
    required this.maxImageSizeBytes,
    required this.maxFileSizeBytes,
    required this.apiKey,
    required this.selectedApiKeyId,
    required this.apiFormat,
  });
}
