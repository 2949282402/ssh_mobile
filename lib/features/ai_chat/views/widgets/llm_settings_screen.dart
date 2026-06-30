part of '../llm_chat_screen.dart';

class _LlmSettingsScreen extends StatefulWidget {
  final AiConnectionSettings initialSettings;
  final List<String> initialModels;
  final List<String> initialBaseUrlHistory;
  final List<AiApiKeyHistoryEntry> initialApiKeyHistory;

  const _LlmSettingsScreen({
    required this.initialSettings,
    required this.initialModels,
    required this.initialBaseUrlHistory,
    required this.initialApiKeyHistory,
  });

  @override
  State<_LlmSettingsScreen> createState() => _LlmSettingsScreenState();
}

class _LlmSettingsScreenState extends State<_LlmSettingsScreen> {
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
  String? _errorText;

  late bool _initialRagEnabled;
  late String _initialRagSearchMode;
  late LlmApiFormat _initialApiFormat;

  @override
  void initState() {
    super.initState();
    _baseUrlController =
        TextEditingController(text: widget.initialSettings.baseUrl);
    _modelController =
        TextEditingController(text: widget.initialSettings.model);
    _helperModelController =
        TextEditingController(text: widget.initialSettings.helperModel);
    _auditModelController =
        TextEditingController(text: widget.initialSettings.auditModel);
    _apiKeyController = TextEditingController();
    _quarkApiKeyController = TextEditingController();
    _quarkEndpointController =
        TextEditingController(text: widget.initialSettings.quarkSearchEndpoint);
    _baseUrlHistory = List<String>.from(widget.initialBaseUrlHistory);
    _apiKeyHistory =
        List<AiApiKeyHistoryEntry>.from(widget.initialApiKeyHistory);
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
    _agentLoopMode =
        AiAgentLoopMode.normalize(widget.initialSettings.agentLoopMode);
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
      _baseUrlHistory =
          _baseUrlHistory.where((item) => item != baseUrl).toList();
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

  Future<void> _openBaseUrlHistory(_AiStrings strings) async {
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
          onSelect: (value) => Navigator.pop(
            sheetContext,
            _SettingsHistoryAction.select(value),
          ),
          onDelete: (value) => Navigator.pop(
            sheetContext,
            _SettingsHistoryAction.delete(value),
          ),
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

  Future<void> _openApiKeyHistory(_AiStrings strings) async {
    final action = await showModalBottomSheet<
        _SettingsHistoryAction<AiApiKeyHistoryEntry>>(
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

  Future<void> _refreshModels(_AiStrings strings) async {
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
      setState(() {
        _loadingModels = false;
        _errorText = strings.modelsFailed(e.toString());
      });
    }
  }

  Future<void> _save(_AiStrings strings) async {
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
      setState(() {
        _saving = false;
        _errorText = strings.failed(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _AiStrings(language);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.settings),
        actions: _hasChanges()
            ? [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
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
                    onPressed: () => Navigator.pop(context),
                    child: Text(strings.close),
                  ),
                ),
              ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            DropdownButtonFormField<LlmApiFormat>(
              initialValue: _apiFormat,
              decoration: InputDecoration(
                labelText: strings.apiFormat,
              ),
              items: const [
                LlmApiFormat.openAiChatCompletions,
                LlmApiFormat.geminiOpenAiCompatible,
                LlmApiFormat.anthropicMessages,
              ].map((format) {
                return DropdownMenuItem<LlmApiFormat>(
                  value: format,
                  child: Text(strings.apiFormatLabel(format)),
                );
              }).toList(),
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _apiFormat = value;
                      });
                    },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _baseUrlController,
              decoration: InputDecoration(
                labelText: strings.baseUrl,
                helperText: _baseUrlHistory.isEmpty
                    ? null
                    : strings.savedCount(_baseUrlHistory.length),
                suffixIcon: IconButton(
                  tooltip: strings.baseUrlHistory,
                  onPressed:
                      _saving ? null : () => _openBaseUrlHistory(strings),
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      '${strings.recommendedBaseUrl}: ${_getRecommendedBaseUrl(_apiFormat)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () {
                            setState(() {
                              _baseUrlController.text =
                                  _getRecommendedBaseUrl(_apiFormat);
                            });
                          },
                    child: Text(strings.useRecommendedBaseUrl),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _apiKeyController,
              enabled: !_saving,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _selectedApiKeyMasked != null
                    ? strings.apiKeySaved
                    : strings.apiKeyRequired,
                helperText: _selectedApiKeyMasked != null
                    ? strings.apiKeySelected(_selectedApiKeyMasked!)
                    : (_apiKeyHistory.isNotEmpty
                        ? strings.apiKeyHistoryHint
                        : strings.apiKeyReplaceHint),
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  tooltip: strings.apiKeyHistory,
                  onPressed: _saving ? null : () => _openApiKeyHistory(strings),
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                ),
              ),
            ),
            if (_apiKeyHistory.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in _apiKeyHistory)
                    ChoiceChip(
                      label: Text(entry.maskedValue),
                      selected: entry.id == _selectedApiKeyId,
                      onSelected: _saving
                          ? null
                          : (_) => _selectApiKeyHistoryEntry(entry.id),
                    ),
                ],
              ),
              if (_selectedApiKeyMasked != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    strings.apiKeyMaskedPreview(_selectedApiKeyMasked!),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _models.contains(_modelController.text)
                        ? _modelController.text
                        : _models.first,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: strings.model),
                    selectedItemBuilder: (context) => [
                      for (final model in _models)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                          ),
                        ),
                    ],
                    items: [
                      for (final model in _models)
                        DropdownMenuItem(
                          value: model,
                          child: Text(
                            model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                          ),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _modelController.text = value);
                            }
                          },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: strings.refreshModels,
                  onPressed: _loadingModels || _saving
                      ? null
                      : () => _refreshModels(strings),
                  icon: _loadingModels
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _helperModelController,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: strings.helperModel,
                helperText: strings.helperModelHint,
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _auditModelController,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: strings.auditModel,
                helperText: strings.auditModelHint,
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: AgentModelFallbackPolicy.normalize(
                _modelFallbackPolicy,
              ),
              isExpanded: true,
              decoration: InputDecoration(
                labelText: strings.modelFallbackPolicy,
              ),
              items: [
                for (final value in AgentModelFallbackPolicy.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(strings.modelFallbackPolicyLabel(value)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _modelFallbackPolicy = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: _contextWindowTokens,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Context window'),
              items: [
                for (final value in AiContextWindowSize.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(AiContextWindowSize.label(value)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _contextWindowTokens = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: _timeoutSeconds,
              isExpanded: true,
              decoration: InputDecoration(labelText: strings.requestTimeout),
              items: [
                for (final value in AiRequestTimeout.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(AiRequestTimeout.label(value)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _timeoutSeconds = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(strings.multiAgent),
              subtitle: Text(strings.multiAgentHint),
              value: _multiAgentEnabled,
              onChanged: _saving
                  ? null
                  : (value) {
                      setState(() => _multiAgentEnabled = value);
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: AiMultiAgentMaxAgents.normalize(
                _multiAgentMaxAgents,
              ),
              isExpanded: true,
              decoration: InputDecoration(
                labelText: strings.multiAgentMaxAgents,
              ),
              items: [
                for (final value in AiMultiAgentMaxAgents.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text('$value'),
                  ),
              ],
              onChanged: _saving || !_multiAgentEnabled
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _multiAgentMaxAgents = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(strings.language == AppLanguage.en
                  ? 'Post-tool review agent'
                  : '异常恢复审查 Agent'),
              subtitle: Text(strings.language == AppLanguage.en
                  ? 'Runs a review agent after tool errors, approval rejection, unavailable approval, budget audit rejection, or loop guard blocking.'
                  : '工具失败、审批拒绝、审批不可用、预算审计拒绝或循环阻断时，自动调用审查 Agent 分析原因并给出下一步建议。'),
              value: _postToolReviewEnabled,
              onChanged: _saving
                  ? null
                  : (value) {
                      setState(() => _postToolReviewEnabled = value);
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: AiToolCallBudget.normalize(_toolCallBudget),
              isExpanded: true,
              decoration: InputDecoration(
                labelText: strings.toolCallBudget,
                helperText: strings.toolCallBudgetHint,
                helperMaxLines: 3,
              ),
              items: [
                for (final value in AiToolCallBudget.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(AiToolCallBudget.label(value)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _toolCallBudget = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: AiAgentLoopMode.normalize(_agentLoopMode),
              isExpanded: true,
              decoration: InputDecoration(
                labelText: strings.language == AppLanguage.en
                    ? 'Agent loop rounds'
                    : 'Agent 循环轮次',
                helperText: strings.language == AppLanguage.en
                    ? 'Controls primary model rounds separately from tool call budget. Balanced 16 (+8), Deep 24 (+12), Unlimited has no round cap. Tool call budget is unchanged.'
                    : '单独控制主模型循环轮次，不影响工具调用预算。均衡 16（批准 +8），深度 24（批准 +12），无限制不设轮次上限。工具预算保持不变。',
                helperMaxLines: 4,
              ),
              items: [
                for (final value in AiAgentLoopMode.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(
                      switch (value) {
                        AiAgentLoopMode.deep =>
                          strings.language == AppLanguage.en ? 'Deep' : '深度',
                        AiAgentLoopMode.unlimited =>
                          strings.language == AppLanguage.en
                              ? 'Unlimited'
                              : '无限制',
                        _ => strings.language == AppLanguage.en
                            ? 'Balanced'
                            : '均衡',
                      },
                    ),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(
                          () => _agentLoopMode = AiAgentLoopMode.normalize(
                            value,
                          ),
                        );
                      }
                    },
            ),
            if (_showsDeepSeekControls) ...[
              const SizedBox(height: 14),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(strings.deepSeekThinking),
                subtitle: Text(strings.deepSeekThinkingHint),
                value: _deepSeekThinkingEnabled,
                onChanged: _saving
                    ? null
                    : (value) {
                        setState(() => _deepSeekThinkingEnabled = value);
                      },
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue:
                    DeepSeekReasoningEffort.normalize(_deepSeekReasoningEffort),
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: strings.deepSeekReasoningEffort,
                ),
                items: [
                  for (final value in DeepSeekReasoningEffort.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(DeepSeekReasoningEffort.label(value)),
                    ),
                ],
                onChanged: _saving || !_deepSeekThinkingEnabled
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _deepSeekReasoningEffort = value);
                        }
                      },
              ),
            ],
            if (_showsOpenAiReasoningControls) ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: OpenAiReasoningEffort.normalize(
                  _openAiReasoningEffort,
                ),
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: strings.openAiReasoningEffort,
                  helperText: strings.openAiReasoningHint,
                ),
                items: [
                  for (final value in OpenAiReasoningEffort.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(OpenAiReasoningEffort.label(value)),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _openAiReasoningEffort = value);
                        }
                      },
              ),
            ],
            const SizedBox(height: 14),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(strings.webSearch),
              subtitle: Text(strings.webSearchHint),
              value: _webSearchEnabled,
              onChanged: _saving
                  ? null
                  : (value) {
                      setState(() => _webSearchEnabled = value);
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _webSearchEngine,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: strings.webSearchEngine,
              ),
              items: [
                for (final value in AiWebSearchEngine.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(strings.webSearchEngineLabel(value)),
                  ),
              ],
              onChanged: _saving || !_webSearchEnabled
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _webSearchEngine = value);
                      }
                    },
            ),
            if (_webSearchEnabled &&
                _webSearchEngine == AiWebSearchEngine.quark) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _quarkApiKeyController,
                enabled: !_saving,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: widget.initialSettings.hasQuarkApiKey
                      ? strings.quarkApiKeySaved
                      : strings.quarkApiKeyRequired,
                  helperText: strings.quarkApiKeyReplaceHint,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _quarkEndpointController,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: strings.quarkSearchEndpoint,
                  helperText: strings.quarkSearchEndpointHint,
                  helperMaxLines: 2,
                ),
              ),
            ],
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: AiWebSearchMaxResults.normalize(
                _webSearchMaxResults,
              ),
              isExpanded: true,
              decoration:
                  InputDecoration(labelText: strings.webSearchMaxResults),
              items: [
                for (final value in AiWebSearchMaxResults.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text('$value'),
                  ),
              ],
              onChanged: _saving || !_webSearchEnabled
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _webSearchMaxResults = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(strings.ragTitle),
              subtitle: Text(strings.ragHint),
              value: _ragEnabled,
              onChanged: _saving
                  ? null
                  : (value) {
                      setState(() => _ragEnabled = value);
                    },
            ),
            if (_ragEnabled) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _ragSearchMode,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: strings.ragSearchMode,
                ),
                items: [
                  DropdownMenuItem(
                    value: 'bm25',
                    child: Text(strings.ragSearchModeBm25),
                  ),
                  DropdownMenuItem(
                    value: 'vector',
                    child: Text(strings.ragSearchModeVector),
                  ),
                  DropdownMenuItem(
                    value: 'hybrid',
                    child: Text(strings.ragSearchModeHybrid),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _ragSearchMode = value);
                        }
                      },
              ),
              if (_ragSearchMode == 'vector' || _ragSearchMode == 'hybrid') ...[
                const SizedBox(height: 8),
                Text(
                  strings.ragSearchModeNeedKey,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_stories),
              label: Text(strings.ragManage),
              onPressed: _saving
                  ? null
                  : () {
                      Navigator.pushNamed(context, '/rag-knowledge');
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue:
                  AiUploadSizeLimit.normalizeImage(_maxImageSizeBytes),
              isExpanded: true,
              decoration: InputDecoration(labelText: strings.maxImageSize),
              items: [
                for (final value in AiUploadSizeLimit.imageValues)
                  DropdownMenuItem(
                    value: value,
                    child: Text(AiUploadSizeLimit.label(value)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _maxImageSizeBytes = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: AiUploadSizeLimit.normalizeFile(_maxFileSizeBytes),
              isExpanded: true,
              decoration: InputDecoration(labelText: strings.maxFileSize),
              items: [
                for (final value in AiUploadSizeLimit.fileValues)
                  DropdownMenuItem(
                    value: value,
                    child: Text(AiUploadSizeLimit.label(value)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _maxFileSizeBytes = value);
                      }
                    },
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.36),
                  borderRadius: BorderRadius.circular(8),
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
            ],
          ],
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

  const _SettingsHistoryAction._({
    required this.value,
    required this.delete,
  });

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
