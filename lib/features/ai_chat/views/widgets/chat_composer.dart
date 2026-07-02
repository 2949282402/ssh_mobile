part of '../llm_chat_screen.dart';

class _ChatComposer extends StatefulWidget {
  final TextEditingController inputController;
  final FocusNode inputFocusNode;
  final bool toolsExpanded;
  final ValueChanged<bool> onToolsExpandedChanged;
  final VoidCallback onSubmit;
  final VoidCallback onStop;

  const _ChatComposer({
    required this.inputController,
    required this.inputFocusNode,
    required this.toolsExpanded,
    required this.onToolsExpandedChanged,
    required this.onSubmit,
    required this.onStop,
  });

  @override
  State<_ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<_ChatComposer> {
  late final ValueNotifier<String> _textNotifier;

  @override
  void initState() {
    super.initState();
    _textNotifier = ValueNotifier<String>(widget.inputController.text);
    widget.inputController.addListener(_onInputTextChanged);
  }

  @override
  void dispose() {
    widget.inputController.removeListener(_onInputTextChanged);
    _textNotifier.dispose();
    super.dispose();
  }

  void _onInputTextChanged() {
    if (_textNotifier.value != widget.inputController.text) {
      _textNotifier.value = widget.inputController.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);
    final state = context.findAncestorStateOfType<_LlmChatScreenBodyState>()!;

    return Selector<AiChatViewModel, _ComposerSnapshot>(
      selector: (context, vm) {
        final activeChat = vm.activeChat!;
        return _ComposerSnapshot(
          chatId: activeChat.id,
          planMode: activeChat.planMode,
          sending: vm.sending,
          hasPendingAttachments: vm.pendingAttachments.isNotEmpty,
          pendingAttachmentsCount: vm.pendingAttachments.length,
          selectedConnectionIds:
              Set<String>.unmodifiable(vm.selectedConnectionIds),
          connectionsCount: vm.connections.length,
        );
      },
      builder: (context, snapshot, child) {
        final viewModel = context.read<AiChatViewModel>();
        final activeChat = viewModel.activeChat!;

        return Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            border: Border(
              top: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          child: SingleChildScrollView(
            reverse: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 1. Plan Mode active banner
                ValueListenableBuilder<String>(
                  valueListenable: _textNotifier,
                  builder: (context, text, _) {
                    final isPlanInput = text.trim().startsWith('/plan');
                    final showPlanMode = snapshot.planMode || isPlanInput;
                    if (!showPlanMode) return const SizedBox.shrink();
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: colorScheme.primary.withValues(alpha: 0.24),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.edit_note_rounded,
                            size: 18,
                            color: colorScheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              strings.language == AppLanguage.en
                                  ? 'Plan Mode Active (Read-only diagnostics & planning)'
                                  : '规划模式已启用 (仅进行只读诊断与方案规划)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () async {
                              if (isPlanInput) {
                                widget.inputController.clear();
                              }
                              if (snapshot.planMode) {
                                await state._setPlanModeFromUi(
                                  chat: activeChat,
                                  enabled: false,
                                  strings: strings,
                                );
                              }
                            },
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                // 2. Slash command suggestions panel
                ValueListenableBuilder<String>(
                  valueListenable: _textNotifier,
                  builder: (context, text, _) {
                    if (!state._shouldShowSlashCommandPanel) {
                      return const SizedBox.shrink();
                    }
                    return state._buildSlashCommandPanel(context, strings);
                  },
                ),

                // 3. Attachment previews
                const _ChatAttachmentPreview(),

                // 4. Text Input & Send buttons Row
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.inputController,
                        focusNode: widget.inputFocusNode,
                        minLines: 1,
                        maxLines: 3,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(isDense: true),
                        onSubmitted: state._isDesktopPlatform
                            ? null
                            : (_) => widget.onSubmit(),
                        onChanged: (val) {
                          // Handled via listener in composer state
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: strings.tools,
                      icon: AnimatedRotation(
                        turns: widget.toolsExpanded ? 0.125 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: const Icon(Icons.add_rounded),
                      ),
                      onPressed: () {
                        widget.onToolsExpandedChanged(!widget.toolsExpanded);
                      },
                    ),
                    const SizedBox(width: 4),
                    IconButton.filled(
                      tooltip: snapshot.sending ? strings.stop : strings.send,
                      icon: Icon(
                        snapshot.sending
                            ? Icons.stop_rounded
                            : Icons.send_rounded,
                      ),
                      onPressed:
                          snapshot.sending ? widget.onStop : widget.onSubmit,
                    ),
                  ],
                ),

                // 5. Tools expanded drawer
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: widget.toolsExpanded
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _ChatToolsBar(
                            skillsLabel: strings.skills,
                            serverLabel: state._selectedServerLabel(strings),
                            webViewLabel: strings.webView,
                            imageLabel: strings.attachImage,
                            fileLabel: strings.attachFile,
                            ragLabel: strings.ragTitle,
                            promptLabel: strings.promptLabel,
                            planModeLabel: strings.planMode,
                            playbooksLabel: strings.playbooks,
                            isPlanModeActive: snapshot.planMode,
                            onServerTap: () =>
                                state._selectTargetServer(strings),
                            onSkillsTap: () {
                              Navigator.pushNamed(context, '/ai-skills');
                            },
                            onWebViewTap: () =>
                                state._openClientWebView(snapshot.chatId),
                            onImageTap: () => state._pickImage(strings),
                            onFileTap: () => state._pickFile(strings),
                            onRagTap: () =>
                                state._showRagBottomSheet(context, strings),
                            onPromptTap: () =>
                                state._showPromptCustomizer(strings),
                            onPlanModeTap: () => state._setPlanModeFromUi(
                              chat: activeChat,
                              enabled: !snapshot.planMode,
                              strings: strings,
                            ),
                            onPlaybooksTap: () {
                              Navigator.pushNamed(context, '/playbooks');
                            },
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
