part of '../llm_chat_screen.dart';

class _ChatMessageList extends StatelessWidget {
  final ScrollController scrollController;
  final ValueChanged<ScrollMetrics> onUserScroll;
  final void Function(int index) onEditUser;
  final void Function(int index) onRegenerate;
  final void Function(int index) onBranch;
  final VoidCallback onContinueTimeout;

  const _ChatMessageList({
    required this.scrollController,
    required this.onUserScroll,
    required this.onEditUser,
    required this.onRegenerate,
    required this.onBranch,
    required this.onContinueTimeout,
  });

  bool _isTimeoutError(String text) {
    final lower = text.toLowerCase();
    return lower.contains('timeout') || text.contains('超时');
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _AiStrings(language);

    return Selector<AiChatViewModel, _ChatMessagesSnapshot>(
      selector: (context, vm) {
        final activeChat = vm.activeChat!;
        return _ChatMessagesSnapshot(
          chatId: activeChat.id,
          messages: activeChat.messages,
          sending: vm.sending,
        );
      },
      builder: (context, snapshot, child) {
        final visibleMessages = snapshot.messages.isEmpty
            ? [
                AiChatMessageRecord(
                  role: 'assistant',
                  text: strings.welcome,
                  createdAt: DateTime.now(),
                ),
              ]
            : snapshot.messages;

        final viewModel = context.read<AiChatViewModel>();

        return TweenAnimationBuilder<double>(
          key: ValueKey('chat-body-${snapshot.chatId}'),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, 18 * (1 - value)),
                child: child,
              ),
            );
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.vertical &&
                  (notification is UserScrollNotification ||
                      notification is ScrollEndNotification)) {
                onUserScroll(notification.metrics);
              }
              return false;
            },
            child: ListView.builder(
              controller: scrollController,
              cacheExtent: 900.0,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
              itemCount: visibleMessages.length,
              itemBuilder: (context, index) {
                final message = visibleMessages[index];
                final streamingTextListenable =
                    viewModel.streamingTextFor(snapshot.chatId, message);
                final streamingStatusListenable =
                    viewModel.streamingStatusFor(snapshot.chatId, message);

                return RepaintBoundary(
                  key: ValueKey(
                    '${message.role}-${message.createdAt.microsecondsSinceEpoch}',
                  ),
                  child: _MessageBubble(
                    chatId: snapshot.chatId,
                    index: index,
                    message: message,
                    streamingTextListenable: streamingTextListenable,
                    streamingStatusListenable: streamingStatusListenable,
                    canAct: !snapshot.sending &&
                        snapshot.messages == visibleMessages,
                    onEditUser:
                        message.role == 'user' ? () => onEditUser(index) : null,
                    onRegenerate: message.role == 'assistant'
                        ? () => onRegenerate(index)
                        : null,
                    onBranch: message.role == 'assistant'
                        ? () => onBranch(index)
                        : null,
                    onContinueTimeout: message.role == 'error' &&
                            index == visibleMessages.length - 1 &&
                            _isTimeoutError(message.text)
                        ? onContinueTimeout
                        : null,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
