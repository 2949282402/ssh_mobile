part of '../llm_chat_screen.dart';

class _ChatHistoryOverlay extends StatelessWidget {
  final AiStrings strings;

  const _ChatHistoryOverlay({required this.strings});

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_LlmChatScreenBodyState>()!;
    final width = state._historyPanelWidth(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Selector<AiChatViewModel, _HistoryPanelSnapshot>(
      selector: (_, vm) => _HistoryPanelSnapshot(
        savedHistoryChats: vm.savedHistoryChats,
        activeChatId: vm.activeChatId,
        historyLoading: vm.historyLoading,
      ),
      builder: (context, snapshot, _) {
        final viewModel = context.read<AiChatViewModel>();
        return ValueListenableBuilder<double>(
          valueListenable: state._historyPanelExtent,
          builder: (context, rawExtent, _) {
            final extent = rawExtent.clamp(0.0, width);
            if (extent <= 0.5) return const SizedBox.shrink();
            final progress = width == 0 ? 0.0 : extent / width;
            return Positioned.fill(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => state._closeHistoryPanel(context),
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.28 * progress),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: extent - width,
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
                          child: _HistoryPanel(
                            chats: snapshot.savedHistoryChats,
                            activeChatId: snapshot.activeChatId,
                            loading: snapshot.historyLoading,
                            strings: strings,
                            formatTime: state._formatTime,
                            onClose: () => state._closeHistoryPanel(context),
                            onNewChat: () {
                              state._closeHistoryPanel(context);
                              viewModel.createChatFromSettings();
                            },
                            onDeleteChat: (chat) async {
                              await state._deleteChat(chat);
                            },
                            onSelectChat: (chatId) {
                              viewModel.selectChat(chatId);
                              state._closeHistoryPanel(context);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
