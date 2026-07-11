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
    final mediaQuery = MediaQuery.of(context);
    final mobileMetrics = mobileUiMetricsFor(mediaQuery);

    return Selector<AiChatViewModel, _ComposerSnapshot>(
      selector: (context, vm) {
        final activeChat = vm.activeChat!;
        return _ComposerSnapshot(
          chatId: activeChat.id,
          planMode: activeChat.planMode,
          sending: vm.sending,
          hasPendingAttachments: vm.pendingAttachments.isNotEmpty,
          pendingAttachmentsCount: vm.pendingAttachments.length,
          selectedConnectionIds: Set<String>.unmodifiable(
            vm.selectedConnectionIds,
          ),
          connectionsCount: vm.connections.length,
        );
      },
      builder: (context, snapshot, child) {
        final viewModel = context.read<AiChatViewModel>();
        final activeChat = viewModel.activeChat!;
        final horizontalPadding = 12 * mobileMetrics.chromeScale;
        final verticalPadding = 9 * mobileMetrics.chromeScale;

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: chatComposerMaxHeightFor(
              viewportHeight: mediaQuery.size.height,
              keyboardInset: mediaQuery.viewInsets.bottom,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.96),
              border: Border(
                top: BorderSide(
                  color: colorScheme.outline.withValues(alpha: 0.56),
                ),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                verticalPadding,
                horizontalPadding,
                verticalPadding,
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Flexible(
                        fit: FlexFit.loose,
                        child: SingleChildScrollView(
                          physics: const ClampingScrollPhysics(),
                          child: _buildAuxiliaryContent(
                            context: context,
                            snapshot: snapshot,
                            activeChat: activeChat,
                            viewModel: viewModel,
                            state: state,
                            strings: strings,
                            colorScheme: colorScheme,
                          ),
                        ),
                      ),
                      _buildInputSurface(
                        colorScheme: colorScheme,
                        strings: strings,
                        state: state,
                        sending: snapshot.sending,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAuxiliaryContent({
    required BuildContext context,
    required _ComposerSnapshot snapshot,
    required AiChatRecord activeChat,
    required AiChatViewModel viewModel,
    required _LlmChatScreenBodyState state,
    required AiStrings strings,
    required ColorScheme colorScheme,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPlanBanner(
          context: context,
          snapshot: snapshot,
          activeChat: activeChat,
          strings: strings,
          colorScheme: colorScheme,
        ),
        ValueListenableBuilder<String>(
          valueListenable: _textNotifier,
          builder: (context, text, _) {
            return ChatSlashCommandsPanel(
              inputController: state._inputController,
              strings: strings,
              onStateChanged: () {
                _textNotifier.value = state._inputController.text;
              },
            );
          },
        ),
        const _ChatAttachmentPreview(),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: widget.toolsExpanded
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ChatToolsBar(
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
                    onServerTap: () => state._selectTargetServer(strings),
                    onSkillsTap: () {
                      Navigator.pushNamed(context, '/ai-skills');
                    },
                    onWebViewTap: () =>
                        state._openClientWebView(snapshot.chatId),
                    onImageTap: () => ChatAttachmentPicker.pickImage(
                      context,
                      strings,
                      viewModel,
                    ),
                    onFileTap: () => ChatAttachmentPicker.pickFile(
                      context,
                      strings,
                      viewModel,
                    ),
                    onRagTap: () => ChatRagSheet.show(context, strings),
                    onPromptTap: () => state._showPromptCustomizer(strings),
                    onPlanModeTap: () =>
                        LlmChatCommandsHelper.setPlanModeFromUi(
                          context: context,
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
    );
  }

  Widget _buildPlanBanner({
    required BuildContext context,
    required _ComposerSnapshot snapshot,
    required AiChatRecord activeChat,
    required AiStrings strings,
    required ColorScheme colorScheme,
  }) {
    return ValueListenableBuilder<String>(
      valueListenable: _textNotifier,
      builder: (context, text, _) {
        final isPlanInput = text.trim().startsWith('/plan');
        final showPlanMode = snapshot.planMode || isPlanInput;
        if (!showPlanMode) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
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
              const SizedBox(width: 8),
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
              IconButton(
                tooltip: strings.close,
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(48),
                  foregroundColor: colorScheme.onPrimaryContainer,
                ),
                onPressed: () async {
                  if (isPlanInput) widget.inputController.clear();
                  if (snapshot.planMode) {
                    await LlmChatCommandsHelper.setPlanModeFromUi(
                      context: context,
                      chat: activeChat,
                      enabled: false,
                      strings: strings,
                    );
                  }
                },
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInputSurface({
    required ColorScheme colorScheme,
    required AiStrings strings,
    required _LlmChatScreenBodyState state,
    required bool sending,
  }) {
    return Container(
      key: const ValueKey<String>('chat-composer-surface'),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.62)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            key: const ValueKey<String>('chat-composer-tools'),
            tooltip: strings.tools,
            style: IconButton.styleFrom(
              minimumSize: const Size.square(48),
              foregroundColor: colorScheme.primary,
            ),
            icon: AnimatedRotation(
              turns: widget.toolsExpanded ? 0.125 : 0,
              duration: const Duration(milliseconds: 180),
              child: const Icon(Icons.add_rounded),
            ),
            onPressed: () {
              widget.onToolsExpandedChanged(!widget.toolsExpanded);
            },
          ),
          Expanded(
            child: TextField(
              key: const ValueKey<String>('chat-composer-input'),
              controller: widget.inputController,
              focusNode: widget.inputFocusNode,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                hintText: strings.composerHint,
                hintMaxLines: 1,
                hintStyle: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onSubmitted: state._isDesktopPlatform
                  ? null
                  : (_) => widget.onSubmit(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: IconButton(
              key: const ValueKey<String>('chat-composer-send'),
              tooltip: sending ? strings.stop : strings.send,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(48),
                foregroundColor: colorScheme.onPrimary,
                backgroundColor: colorScheme.primary,
              ),
              icon: Icon(
                sending ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              ),
              onPressed: sending ? widget.onStop : widget.onSubmit,
            ),
          ),
        ],
      ),
    );
  }
}
