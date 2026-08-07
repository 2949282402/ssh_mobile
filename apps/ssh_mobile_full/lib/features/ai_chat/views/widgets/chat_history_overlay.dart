part of '../llm_chat_screen.dart';

class ChatHistoryBackScope extends StatelessWidget {
  const ChatHistoryBackScope({
    super.key,
    required this.historyVisible,
    required this.onCloseHistory,
    required this.child,
  });

  final bool historyVisible;
  final VoidCallback onCloseHistory;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !historyVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && historyVisible) onCloseHistory();
      },
      child: child,
    );
  }
}

class _ChatHistoryOverlay extends StatelessWidget {
  final AiStrings strings;

  const _ChatHistoryOverlay({required this.strings});

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_LlmChatScreenBodyState>()!;
    final width = MediaQuery.sizeOf(context).width;
    final colorScheme = Theme.of(context).colorScheme;

    return Selector<AiChatViewModel, _HistoryPanelSnapshot>(
      selector: (_, vm) => _HistoryPanelSnapshot(
        chats: vm.chats,
        activeChatId: vm.activeChatId,
        historyLoading: vm.historyLoading,
      ),
      builder: (context, snapshot, _) {
        final viewModel = context.read<AiChatViewModel>();
        return ValueListenableBuilder<double>(
          valueListenable: state._historyPanelProgress,
          builder: (context, rawProgress, _) {
            final progress = rawProgress.clamp(0.0, 1.0);
            if (progress <= 0.001) return const SizedBox.shrink();
            return Positioned.fill(
              child: BlockSemantics(
                child: Semantics(
                  container: true,
                  scopesRoute: true,
                  namesRoute: true,
                  explicitChildNodes: true,
                  label: strings.history,
                  child: FocusScope(
                    autofocus: true,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Semantics(
                            button: true,
                            label: strings.close,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              excludeFromSemantics: true,
                              onTap: state._closeHistoryPanel,
                              child: ColoredBox(
                                color: Colors.black.withValues(
                                  alpha: 0.28 * progress,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          bottom: 0,
                          left: historyPanelLeadingOffsetFor(
                            width: width,
                            progress: progress,
                          ),
                          width: width,
                          child: SafeArea(
                            child: Material(
                              color: colorScheme.surface,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border(
                                    right: BorderSide(
                                      color: colorScheme.outlineVariant,
                                      width: 1,
                                    ),
                                  ),
                                ),
                                child: HistoryPanel(
                                  chats: snapshot.chats,
                                  activeChatId: snapshot.activeChatId,
                                  loading: snapshot.historyLoading,
                                  strings: strings,
                                  formatTime: state._formatTime,
                                  onClose: state._closeHistoryPanel,
                                  onNewChat: () {
                                    state._closeHistoryPanel();
                                    unawaited(state._createNewChat());
                                  },
                                  onDeleteChat: (chat) async {
                                    await state._deleteChat(chat);
                                  },
                                  onSelectChat: (chatId) {
                                    viewModel.selectChat(chatId);
                                    state._closeHistoryPanel();
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
