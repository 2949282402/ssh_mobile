part of '../llm_chat_screen.dart';

@visibleForTesting
Future<bool> closePlanModeBannerForInput({
  required TextEditingController controller,
  required bool persistedPlanMode,
  required Future<bool> Function() disablePersistedPlanMode,
}) async {
  if (persistedPlanMode) {
    final disabled = await disablePersistedPlanMode();
    if (!disabled) return false;
  }
  // Re-read after persistence: the user may keep editing while the save is in
  // flight. Only remove a Plan token that is still present in the live draft.
  final parsedCommand = parsePlanCommand(controller.text);
  if (parsedCommand != null) {
    final arguments = parsedCommand.arguments;
    controller.value = TextEditingValue(
      text: arguments,
      selection: TextSelection.collapsed(offset: arguments.length),
    );
  }
  return true;
}

class ChatPlanModeBanner extends StatelessWidget {
  final AiStrings strings;
  final bool persistedPlanMode;
  final bool busy;
  final VoidCallback? onClose;

  const ChatPlanModeBanner({
    super.key,
    required this.strings,
    required this.persistedPlanMode,
    required this.busy,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final closeLabel = persistedPlanMode
        ? strings.planModeDisableAction
        : strings.planModeRemoveCommand;
    return Semantics(
      container: true,
      selected: true,
      label: '${strings.planMode}. ${strings.planModeReadOnlyHint}',
      child: Material(
        key: const ValueKey<String>('plan-mode-banner'),
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.8),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.edit_note_rounded,
                size: 20,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.planMode,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        strings.planModeReadOnlyHint,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey<String>('plan-mode-banner-close'),
                tooltip: closeLabel,
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(48),
                  foregroundColor: colorScheme.onSurfaceVariant,
                ),
                onPressed: busy ? null : onClose,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatComposer extends StatefulWidget {
  final double availableHeight;
  final TextEditingController inputController;
  final FocusNode inputFocusNode;
  final bool toolsExpanded;
  final ValueChanged<bool> onToolsExpandedChanged;
  final VoidCallback onSubmit;
  final VoidCallback onStop;

  const _ChatComposer({
    required this.availableHeight,
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
  bool _planModeUiInFlight = false;

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

  Future<bool> _setPlanMode({
    required BuildContext context,
    required AiChatRecord chat,
    required bool enabled,
    required AiStrings strings,
  }) async {
    if (_planModeUiInFlight) return false;
    setState(() => _planModeUiInFlight = true);
    try {
      return await LlmChatCommandsHelper.setPlanModeFromUi(
        context: context,
        chat: chat,
        enabled: enabled,
        strings: strings,
      );
    } finally {
      if (mounted) setState(() => _planModeUiInFlight = false);
    }
  }

  Future<void> _closePlanModeBanner({
    required BuildContext context,
    required _ComposerSnapshot snapshot,
    required AiChatRecord chat,
    required AiStrings strings,
  }) async {
    await closePlanModeBannerForInput(
      controller: widget.inputController,
      persistedPlanMode: snapshot.planMode,
      disablePersistedPlanMode: () => _setPlanMode(
        context: context,
        chat: chat,
        enabled: false,
        strings: strings,
      ),
    );
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
          planApprovalInFlight: vm.planApprovalInFlight,
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
              viewportHeight: widget.availableHeight,
              keyboardInset: 0,
              textScale: mediaQuery.textScaler.scale(14) / 14,
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
                    isPlanModeBusy:
                        _planModeUiInFlight ||
                        snapshot.sending ||
                        snapshot.planApprovalInFlight,
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
                    onPlanModeTap: () => _setPlanMode(
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
  }) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    if (!shouldShowPlanModeBannerForAvailableHeight(
      availableHeight: widget.availableHeight,
      textScale: textScale,
    )) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<String>(
      valueListenable: _textNotifier,
      builder: (context, text, _) {
        final isPlanInput = parsePlanCommand(text) != null;
        final showPlanMode = snapshot.planMode || isPlanInput;
        if (!showPlanMode) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ChatPlanModeBanner(
            strings: strings,
            persistedPlanMode: snapshot.planMode,
            busy:
                _planModeUiInFlight ||
                snapshot.sending ||
                snapshot.planApprovalInFlight,
            onClose: () => _closePlanModeBanner(
              context: context,
              snapshot: snapshot,
              chat: activeChat,
              strings: strings,
            ),
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
        color: Colors.transparent,
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
            padding: const EdgeInsets.only(
              right: 8,
              top: 6,
              bottom: 6,
              left: 4,
            ),
            child: IconButton(
              key: const ValueKey<String>('chat-composer-send'),
              tooltip: sending ? strings.stop : strings.send,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(38),
                padding: EdgeInsets.zero,
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
