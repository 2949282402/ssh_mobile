part of '../llm_chat_screen.dart';

class PromptCustomizerDialog extends StatefulWidget {
  final AiStrings strings;

  const PromptCustomizerDialog({super.key, required this.strings});

  @override
  State<PromptCustomizerDialog> createState() => _PromptCustomizerDialogState();
}

class _PromptCustomizerDialogState extends State<PromptCustomizerDialog> {
  bool _loading = true;
  bool _saving = false;
  bool _discardDialogOpen = false;
  bool _useCustomPrompts = false;
  String? _errorText;

  // 用于编辑这 6 种 prompt 的 controller 缓存数据
  final Map<String, String> _customPrompts = {
    'system': '',
    'planner': '',
    'operator': '',
    'explore': '',
    'reviewer': '',
    'summarizer': '',
  };
  final Map<String, String> _initialCustomPrompts = {};
  bool _initialUseCustomPrompts = false;

  String _activeType = 'system';
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController()..addListener(_handleTextChanged);
    _loadSettings();
  }

  void _handleTextChanged() {
    if (mounted && !_loading) setState(() {});
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorText = null;
      });
    }
    try {
      final viewModel = context.read<AiChatViewModel>();
      final settings = await viewModel.loadAiConnectionSettings();
      if (!mounted) return;

      setState(() {
        _useCustomPrompts = settings.useCustomPrompts;
        _customPrompts['system'] = settings.customSystemPrompt;
        _customPrompts['planner'] = settings.customPlannerPrompt;
        _customPrompts['operator'] = settings.customOperatorPrompt;
        _customPrompts['explore'] = settings.customExplorePrompt;
        _customPrompts['reviewer'] = settings.customReviewerPrompt;
        _customPrompts['summarizer'] = settings.customSummarizerPrompt;
        _initialUseCustomPrompts = _useCustomPrompts;
        _initialCustomPrompts
          ..clear()
          ..addAll(_customPrompts);
        _setControllerText(_getCurrentPromptValue());
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = widget.strings.language == AppLanguage.en
            ? 'Unable to load prompts: $error'
            : '无法加载提示词：$error';
      });
    }
  }

  String _getDefaultPrompt(String type) {
    final isEn = widget.strings.language == AppLanguage.en;
    switch (type) {
      case 'system':
        return isEn ? systemPromptEnPersona : systemPromptZhPersona;
      case 'planner':
        return isEn
            ? multiAgentPlannerPromptEnPersona
            : multiAgentPlannerPromptZhPersona;
      case 'operator':
        return isEn
            ? multiAgentOperatorPromptEnPersona
            : multiAgentOperatorPromptZhPersona;
      case 'explore':
        return isEn
            ? multiAgentExplorePromptEnPersona
            : multiAgentExplorePromptZhPersona;
      case 'reviewer':
        return isEn
            ? multiAgentReviewerPromptEnPersona
            : multiAgentReviewerPromptZhPersona;
      case 'summarizer':
        return isEn
            ? multiAgentSummarizerPromptEnPersona
            : multiAgentSummarizerPromptZhPersona;
      default:
        return '';
    }
  }

  String _getCurrentPromptValue() {
    if (_useCustomPrompts) {
      return _customPrompts[_activeType] ?? '';
    }
    return _getDefaultPrompt(_activeType);
  }

  void _setControllerText(String value) {
    _textController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _syncActivePrompt() {
    if (_useCustomPrompts) {
      _customPrompts[_activeType] = _textController.text;
    }
  }

  bool _hasChanges() {
    if (_loading) return false;
    if (_useCustomPrompts != _initialUseCustomPrompts) return true;
    for (final type in _customPrompts.keys) {
      final currentValue = _useCustomPrompts && type == _activeType
          ? _textController.text
          : _customPrompts[type] ?? '';
      if (currentValue != (_initialCustomPrompts[type] ?? '')) return true;
    }
    return false;
  }

  Future<void> _requestClose() async {
    if (_saving || _discardDialogOpen) return;
    _syncActivePrompt();
    if (!_hasChanges()) {
      Navigator.maybePop(context);
      return;
    }

    final en = widget.strings.language == AppLanguage.en;
    _discardDialogOpen = true;
    final discard = await DestructiveConfirmDialog.show(
      context,
      title: en ? 'Discard prompt changes?' : '放弃提示词更改？',
      content: en
          ? 'Your custom prompt changes have not been saved.'
          : '自定义提示词中的更改尚未保存。',
      cancelLabel: widget.strings.cancel,
      confirmLabel: en ? 'Discard changes' : '放弃更改',
    );
    _discardDialogOpen = false;
    if (discard && mounted) Navigator.pop(context);
  }

  void _setCustomPromptsEnabled(bool value) {
    _syncActivePrompt();
    if (!value) FocusScope.of(context).unfocus();
    setState(() {
      _useCustomPrompts = value;
      if (value) {
        final currentValue = _customPrompts[_activeType] ?? '';
        if (currentValue.trim().isEmpty) {
          _customPrompts[_activeType] = _getDefaultPrompt(_activeType);
        }
      }
    });
    _setControllerText(_getCurrentPromptValue());
  }

  void _onTypeChanged(String? type) {
    if (type == null || type == _activeType) return;
    _syncActivePrompt();
    setState(() {
      _activeType = type;
    });
    _setControllerText(_getCurrentPromptValue());
  }

  void _copyDefaultToCustom() {
    final defaultValue = _getDefaultPrompt(_activeType);
    setState(() {
      _useCustomPrompts = true;
      _customPrompts[_activeType] = defaultValue;
    });
    _setControllerText(defaultValue);
  }

  Future<void> _saveSettings() async {
    if (_saving || !_hasChanges()) return;
    _syncActivePrompt();
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      final viewModel = context.read<AiChatViewModel>();
      final settings = await viewModel.loadAiConnectionSettings();
      await viewModel.saveAiConnectionSettings(
        baseUrl: settings.baseUrl,
        model: settings.model,
        useCustomPrompts: _useCustomPrompts,
        customSystemPrompt: _customPrompts['system'],
        customPlannerPrompt: _customPrompts['planner'],
        customOperatorPrompt: _customPrompts['operator'],
        customExplorePrompt: _customPrompts['explore'],
        customReviewerPrompt: _customPrompts['reviewer'],
        customSummarizerPrompt: _customPrompts['summarizer'],
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.strings.language == AppLanguage.en
                  ? 'Prompts updated successfully.'
                  : '提示词更新成功。',
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errorText = widget.strings.language == AppLanguage.en
              ? 'Save failed: $e'
              : '保存失败：$e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorText!),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _resetToDefault() {
    if (_saving) return;
    final en = widget.strings.language == AppLanguage.en;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(en ? 'Reset prompts?' : '确认重置提示词？'),
        content: Text(
          en
              ? 'This will clear all custom prompts and revert to default templates. Continue?'
              : '这将清空所有自定义提示词并恢复为系统默认模板。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(widget.strings.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _useCustomPrompts = false;
                _customPrompts.updateAll((key, value) => '');
              });
              _setControllerText(_getDefaultPrompt(_activeType));
            },
            child: Text(en ? 'Reset' : '重置'),
          ),
        ],
      ),
    );
  }

  String _getPromptLabel(String type) {
    final en = widget.strings.language == AppLanguage.en;
    switch (type) {
      case 'system':
        return en ? 'Main System Prompt' : '主 System 提示词';
      case 'planner':
        return en ? 'Agent - Planner' : '智能体 - Planner (规划)';
      case 'explore':
        return en ? 'Agent - Explore' : '智能体 - Explore (探索/信息收集)';
      case 'operator':
        return en ? 'Agent - Operator' : '智能体 - Operator (执行)';
      case 'reviewer':
        return en ? 'Agent - Reviewer' : '智能体 - Reviewer (审计)';
      case 'summarizer':
        return en ? 'Agent - Summarizer' : '智能体 - Summarizer (总结)';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = widget.strings.language == AppLanguage.en;
    final colorScheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final compactKeyboard = usesCompactRailForHeight(mediaQuery.size.height);
    final loadFailed =
        _errorText != null && _initialCustomPrompts.isEmpty && !_loading;

    return PopScope(
      canPop: !_saving && !_hasChanges(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestClose());
      },
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              en ? 'Customize AI Prompts' : '自定义 AI 提示词',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            leading: IconButton(
              key: const ValueKey<String>('prompt-customizer-close'),
              tooltip: en ? 'Close' : '关闭',
              icon: const Icon(Icons.close_rounded),
              onPressed: _saving ? null : _requestClose,
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton(
                  key: const ValueKey<String>('prompt-customizer-save'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _loading || _saving || !_hasChanges()
                      ? null
                      : _saveSettings,
                  child: _saving
                      ? const AppLoadingIndicator(size: 18, strokeWidth: 2)
                      : Text(en ? 'Save' : '保存'),
                ),
              ),
            ],
          ),
          body: AppPageSurface(
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final contentWidth = constraints.maxWidth > 920
                      ? 920.0
                      : constraints.maxWidth;
                  return Center(
                    child: SizedBox(
                      width: contentWidth,
                      height: constraints.maxHeight,
                      child: Padding(
                        padding: EdgeInsets.all(compactKeyboard ? 8 : 14),
                        child: _loading
                            ? _PromptCustomizerSkeleton(strings: widget.strings)
                            : loadFailed
                            ? AppEmptyState(
                                icon: Icons.error_outline_rounded,
                                title: en
                                    ? 'Unable to load prompts'
                                    : '无法加载提示词',
                                message: _errorText!,
                                compact: true,
                                contained: false,
                                action: FilledButton.icon(
                                  key: const ValueKey<String>(
                                    'prompt-customizer-retry',
                                  ),
                                  onPressed: _loadSettings,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: Text(en ? 'Retry' : '重试'),
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_errorText != null &&
                                      !compactKeyboard) ...[
                                    Container(
                                      key: const ValueKey<String>(
                                        'prompt-customizer-error',
                                      ),
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      margin: const EdgeInsets.only(bottom: 12),
                                      decoration: BoxDecoration(
                                        color: colorScheme.errorContainer
                                            .withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(
                                          AppTheme.radiusSmall,
                                        ),
                                        border: Border.all(
                                          color: colorScheme.error.withValues(
                                            alpha: 0.42,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        _errorText!,
                                        style: TextStyle(
                                          color: colorScheme.error,
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (!compactKeyboard) ...[
                                    Material(
                                      type: MaterialType.transparency,
                                      child: SwitchListTile.adaptive(
                                        key: const ValueKey<String>(
                                          'prompt-customizer-enabled',
                                        ),
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(
                                          en
                                              ? 'Enable Custom Prompts'
                                              : '启用自定义提示词',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        subtitle: Text(
                                          en
                                              ? 'Override default templates with edited custom prompts'
                                              : '启用后，将覆盖系统默认模板并使用修改后的提示词',
                                        ),
                                        value: _useCustomPrompts,
                                        onChanged: _saving
                                            ? null
                                            : _setCustomPromptsEnabled,
                                      ),
                                    ),
                                    const Divider(height: 24),
                                  ],
                                  DropdownButtonFormField<String>(
                                    key: const ValueKey<String>(
                                      'prompt-customizer-type',
                                    ),
                                    initialValue: _activeType,
                                    isExpanded: true,
                                    decoration: InputDecoration(
                                      labelText: en ? 'Prompt type' : '提示词类型',
                                    ),
                                    selectedItemBuilder: (context) => [
                                      for (final type in const [
                                        'system',
                                        'planner',
                                        'explore',
                                        'operator',
                                        'reviewer',
                                        'summarizer',
                                      ])
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            _getPromptLabel(type),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                    ],
                                    items: [
                                      for (final type in const [
                                        'system',
                                        'planner',
                                        'explore',
                                        'operator',
                                        'reviewer',
                                        'summarizer',
                                      ])
                                        DropdownMenuItem<String>(
                                          value: type,
                                          child: Text(
                                            _getPromptLabel(type),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                    ],
                                    onChanged: _saving ? null : _onTypeChanged,
                                  ),
                                  SizedBox(height: compactKeyboard ? 6 : 12),
                                  if (compactKeyboard &&
                                      !_useCustomPrompts) ...[
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: ElevatedButton.icon(
                                        key: const ValueKey<String>(
                                          'prompt-customizer-copy-compact',
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          minimumSize: const Size(0, 48),
                                        ),
                                        onPressed: _saving
                                            ? null
                                            : _copyDefaultToCustom,
                                        icon: const Icon(Icons.copy_rounded),
                                        label: Text(
                                          en
                                              ? 'Copy default to edit'
                                              : '复制默认并编辑',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                  ],
                                  if (!compactKeyboard && !_useCustomPrompts)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      margin: const EdgeInsets.only(bottom: 12),
                                      decoration: BoxDecoration(
                                        color: colorScheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.5),
                                        borderRadius: BorderRadius.circular(
                                          AppTheme.radiusSmall,
                                        ),
                                        border: Border.all(
                                          color: colorScheme.outlineVariant,
                                        ),
                                      ),
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final message = Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Icon(
                                                Icons.info_outline,
                                                size: 20,
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  en
                                                      ? 'Safety rules and API logics are frozen by default. Click "Copy to Edit" or toggle enable above to customize.'
                                                      : '系统安全规范与 API 调用逻辑已由系统自动冻结。点击“复制默认并编辑”或开启上方开关以自定义。',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          );
                                          final action = ElevatedButton.icon(
                                            key: const ValueKey<String>(
                                              'prompt-customizer-copy',
                                            ),
                                            onPressed: _saving
                                                ? null
                                                : _copyDefaultToCustom,
                                            icon: const Icon(
                                              Icons.copy_rounded,
                                              size: 16,
                                            ),
                                            label: Text(
                                              en ? 'Copy to Edit' : '复制默认并编辑',
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              minimumSize: const Size(0, 48),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                  ),
                                            ),
                                          );
                                          if (constraints.maxWidth < 560) {
                                            return Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                message,
                                                const SizedBox(height: 8),
                                                Align(
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child: action,
                                                ),
                                              ],
                                            );
                                          }
                                          return Row(
                                            children: [
                                              Expanded(child: message),
                                              const SizedBox(width: 8),
                                              action,
                                            ],
                                          );
                                        },
                                      ),
                                    )
                                  else if (!compactKeyboard)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(8),
                                      margin: const EdgeInsets.only(bottom: 12),
                                      decoration: BoxDecoration(
                                        color: colorScheme.primaryContainer
                                            .withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(
                                          AppTheme.radiusSmall,
                                        ),
                                        border: Border.all(
                                          color: colorScheme.primary.withValues(
                                            alpha: 0.3,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.shield_outlined,
                                            size: 16,
                                            color: colorScheme.primary,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              en
                                                  ? 'Your custom guidelines will be appended to the frozen core logic rules.'
                                                  : '在此编写的自定义指导将安全地附加到系统的核心只读规则之后。',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: colorScheme.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (!compactKeyboard) ...[
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: OutlinedButton.icon(
                                        key: const ValueKey<String>(
                                          'prompt-customizer-reset',
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size(0, 48),
                                        ),
                                        onPressed: _saving
                                            ? null
                                            : _resetToDefault,
                                        icon: const Icon(
                                          Icons.restart_alt_rounded,
                                        ),
                                        label: Text(en ? 'Reset' : '重置'),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  Expanded(
                                    child: TextField(
                                      key: const ValueKey<String>(
                                        'prompt-customizer-editor',
                                      ),
                                      controller: _textController,
                                      expands: true,
                                      minLines: null,
                                      maxLines: null,
                                      keyboardType: TextInputType.multiline,
                                      textInputAction: TextInputAction.newline,
                                      textAlignVertical: TextAlignVertical.top,
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontFamilyFallback: [
                                          'Consolas',
                                          'Microsoft YaHei',
                                          'PingFang SC',
                                          'sans-serif',
                                        ],
                                        fontSize: 13,
                                      ),
                                      decoration: InputDecoration(
                                        labelText: _getPromptLabel(_activeType),
                                        alignLabelWithHint: true,
                                        hintText: en
                                            ? 'Enter custom prompt...'
                                            : '输入自定义提示词内容...',
                                        filled: true,
                                        fillColor: _useCustomPrompts
                                            ? colorScheme.surface
                                            : colorScheme
                                                  .surfaceContainerHighest
                                                  .withValues(alpha: 0.3),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            AppTheme.radiusSmall,
                                          ),
                                        ),
                                      ),
                                      readOnly: !_useCustomPrompts || _saving,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PromptCustomizerSkeleton extends StatelessWidget {
  const _PromptCustomizerSkeleton({required this.strings});

  final AiStrings strings;

  @override
  Widget build(BuildContext context) {
    final en = strings.language == AppLanguage.en;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppSkeletonizer.zone(
      enabled: true,
      semanticsLabel: strings.loadingPrompts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                en ? 'Enable Custom Prompts' : '启用自定义提示词',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                en
                    ? 'Override default templates with edited custom prompts'
                    : '启用后，将覆盖系统默认模板并使用修改后的提示词',
              ),
              value: true,
              onChanged: null,
            ),
          ),
          const Divider(height: 24),
          InputDecorator(
            decoration: InputDecoration(
              labelText: en ? 'Prompt type' : '提示词类型',
            ),
            child: Text(en ? 'System Persona' : '系统主提示词 (System Persona)'),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: const ClipRect(
                child: SingleChildScrollView(
                  physics: NeverScrollableScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'You are an expert DevOps and System Administration AI assistant.',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 13),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Always provide safe, verified terminal commands and clear diagnosis steps.',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 13),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'When modifying server configurations, explain potential impacts and prerequisites.',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.restore_page_outlined, size: 18),
                label: Text(en ? 'Insert default' : '填入默认模板'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: Text(en ? 'Reset' : '重置'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
