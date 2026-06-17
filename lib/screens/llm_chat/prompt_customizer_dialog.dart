part of '../llm_chat_screen.dart';

class _PromptCustomizerDialog extends StatefulWidget {
  final _AiStrings strings;

  const _PromptCustomizerDialog({required this.strings});

  @override
  State<_PromptCustomizerDialog> createState() =>
      _PromptCustomizerDialogState();
}

class _PromptCustomizerDialogState extends State<_PromptCustomizerDialog> {
  bool _loading = true;
  bool _useCustomPrompts = false;

  // 用于编辑这 6 种 prompt 的 controller 缓存数据
  final Map<String, String> _customPrompts = {
    'system': '',
    'planner': '',
    'operator': '',
    'explore': '',
    'reviewer': '',
    'summarizer': '',
  };

  String _activeType = 'system';
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    _loadSettings();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
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

      _textController.text = _getCurrentPromptValue();
      _loading = false;
    });
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

  void _onTypeChanged(String? type) {
    if (type == null || type == _activeType) return;
    // 切换类型前，先把当前的 Controller 内容保存进 Map 里
    if (_useCustomPrompts) {
      _customPrompts[_activeType] = _textController.text;
    }
    setState(() {
      _activeType = type;
      _textController.text = _getCurrentPromptValue();
    });
  }

  void _copyDefaultToCustom() {
    final defaultValue = _getDefaultPrompt(_activeType);
    setState(() {
      _useCustomPrompts = true;
      _customPrompts[_activeType] = defaultValue;
      _textController.text = defaultValue;
    });
  }

  Future<void> _saveSettings() async {
    // 保存前把当前文本同步到内存 Map
    if (_useCustomPrompts) {
      _customPrompts[_activeType] = _textController.text;
    }

    final viewModel = context.read<AiChatViewModel>();
    final settings = await viewModel.loadAiConnectionSettings();

    try {
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
            content: Text(widget.strings.language == AppLanguage.en
                ? 'Prompts updated successfully.'
                : '提示词更新成功。'),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.strings.language == AppLanguage.en
                ? 'Save failed: $e'
                : '保存失败：$e'),
          ),
        );
      }
    }
  }

  void _resetToDefault() {
    final en = widget.strings.language == AppLanguage.en;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(en ? 'Reset prompts?' : '确认重置提示词？'),
        content: Text(en
            ? 'This will clear all custom prompts and revert to default templates. Continue?'
            : '这将清空所有自定义提示词并恢复为系统默认模板。是否继续？'),
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
                _textController.text = _getDefaultPrompt(_activeType);
              });
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

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(en ? 'Customize AI Prompts' : '自定义 AI 提示词'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            TextButton(
              onPressed: _resetToDefault,
              child: Text(en ? 'Reset' : '重置'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saveSettings,
              child: Text(en ? 'Save' : '保存'),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  title: Text(
                    en ? 'Enable Custom Prompts' : '启用自定义提示词',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(en
                      ? 'Override default templates with edited custom prompts'
                      : '启用后，将覆盖系统默认模板并使用修改后的提示词'),
                  value: _useCustomPrompts,
                  onChanged: (val) {
                    setState(() {
                      _useCustomPrompts = val;
                      if (val) {
                        final currentVal = _customPrompts[_activeType] ?? '';
                        if (currentVal.trim().isEmpty) {
                          _customPrompts[_activeType] =
                              _getDefaultPrompt(_activeType);
                        }
                      }
                      _textController.text = _getCurrentPromptValue();
                    });
                  },
                ),
                const Divider(height: 24),
                Row(
                  children: [
                    Text(
                      en ? 'Prompt Type: ' : '提示词类型：',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _activeType,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                        items: [
                          'system',
                          'planner',
                          'explore',
                          'operator',
                          'reviewer',
                          'summarizer'
                        ]
                            .map((type) => DropdownMenuItem<String>(
                                  value: type,
                                  child: Text(
                                    _getPromptLabel(type),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                            .toList(),
                        onChanged: _onTypeChanged,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (!_useCustomPrompts)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            en
                                ? 'Safety rules and API logics are frozen by default. Click "Copy to Edit" or toggle enable above to customize.'
                                : '系统安全规范与 API 调用逻辑已由系统自动冻结。点击“复制默认并编辑”或开启上方开关以自定义。',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _copyDefaultToCustom,
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: Text(en ? 'Copy to Edit' : '复制默认并编辑'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color:
                          colorScheme.primaryContainer.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: colorScheme.primary.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.shield_outlined,
                            size: 16, color: colorScheme.primary),
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
                Expanded(
                  child: TextField(
                    controller: _textController,
                    maxLines: null,
                    minLines: 10,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      hintText: en ? 'Enter custom prompt...' : '输入自定义提示词内容...',
                      filled: true,
                      fillColor: _useCustomPrompts
                          ? colorScheme.surface
                          : colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.3),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    readOnly: !_useCustomPrompts,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
