part of '../llm_chat_screen.dart';

class _ChatMessageList extends StatelessWidget {
  final ScrollController scrollController;
  final ValueChanged<ScrollMetrics> onUserScroll;
  final ValueChanged<String> onSuggestionSelected;
  final void Function(int index) onEditUser;
  final void Function(int index) onRegenerate;
  final void Function(int index) onBranch;
  final VoidCallback onContinueTimeout;

  final void Function(AiChatRecord chat) onRevisePlan;

  const _ChatMessageList({
    required this.scrollController,
    required this.onUserScroll,
    required this.onSuggestionSelected,
    required this.onEditUser,
    required this.onRegenerate,
    required this.onBranch,
    required this.onContinueTimeout,
    required this.onRevisePlan,
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
    final strings = AiStrings(language);

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
        final viewModel = context.read<AiChatViewModel>();

        return TweenAnimationBuilder<double>(
          key: ValueKey('chat-body-${snapshot.chatId}'),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) {
            return Opacity(opacity: value, child: child);
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
            child: snapshot.messages.isEmpty
                ? LayoutBuilder(
                    builder: (context, constraints) =>
                        _buildEmptyList(context, constraints, strings),
                  )
                : ListView.builder(
                    controller: scrollController,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(900.0),
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
                    itemCount: snapshot.messages.length,
                    itemBuilder: (context, index) {
                      final message = snapshot.messages[index];
                      final streamingTextListenable = viewModel
                          .streamingTextFor(snapshot.chatId, message);
                      final streamingStatusListenable = viewModel
                          .streamingStatusFor(snapshot.chatId, message);

                      return RepaintBoundary(
                        key: ValueKey(
                          '${message.role}-${message.createdAt.microsecondsSinceEpoch}',
                        ),
                        child: MessageBubble(
                          chatId: snapshot.chatId,
                          index: index,
                          message: message,
                          streamingTextListenable: streamingTextListenable,
                          streamingStatusListenable: streamingStatusListenable,
                          canAct: !snapshot.sending,
                          onEditUser: message.role == 'user'
                              ? () => onEditUser(index)
                              : null,
                          onRegenerate: message.role == 'assistant'
                              ? () => onRegenerate(index)
                              : null,
                          onBranch: message.role == 'assistant'
                              ? () => onBranch(index)
                              : null,
                          onContinueTimeout:
                              message.role == 'error' &&
                                  index == snapshot.messages.length - 1 &&
                                  _isTimeoutError(message.text)
                              ? onContinueTimeout
                              : null,
                          onRevisePlan: () =>
                              onRevisePlan(viewModel.activeChat!),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyList(
    BuildContext context,
    BoxConstraints constraints,
    AiStrings strings,
  ) {
    final minimumHeight = (constraints.maxHeight - 30).clamp(
      0.0,
      double.infinity,
    );
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: minimumHeight),
          child: AppEmptyState(
            icon: Icons.auto_awesome_rounded,
            title: strings.welcomeTitle,
            message: strings.welcome,
            compact: true,
            contained: false,
            action: _ChatStarterSuggestions(
              strings: strings,
              onSelected: onSuggestionSelected,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatStarterSuggestions extends StatelessWidget {
  const _ChatStarterSuggestions({
    required this.strings,
    required this.onSelected,
  });

  final AiStrings strings;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final availableWidth = (mediaQuery.size.width - 96).clamp(240.0, 520.0);
    final compactHeight = usesCompactRailForHeight(mediaQuery.size.height);
    final tileWidth = compactHeight
        ? (availableWidth - 10) / 2
        : availableWidth.clamp(240.0, 360.0);

    return SizedBox(
      width: availableWidth,
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: [
          _suggestionButton(
            width: tileWidth,
            icon: Icons.monitor_heart_outlined,
            label: strings.checkServersSuggestion,
            prompt: strings.checkServersPrompt,
          ),
          _suggestionButton(
            width: tileWidth,
            icon: Icons.article_outlined,
            label: strings.reviewLogsSuggestion,
            prompt: strings.reviewLogsPrompt,
          ),
          _suggestionButton(
            width: tileWidth,
            icon: Icons.description_outlined,
            label: strings.remoteFileSuggestion,
            prompt: strings.remoteFilePrompt,
          ),
        ],
      ),
    );
  }

  Widget _suggestionButton({
    required double width,
    required IconData icon,
    required String label,
    required String prompt,
  }) {
    return SizedBox(
      width: width,
      height: 48,
      child: OutlinedButton(
        onPressed: () => onSelected(prompt),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 9),
            Expanded(
              child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
