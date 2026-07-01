part of '../llm_chat_screen.dart';

class _ChatHeader extends StatelessWidget {
  final VoidCallback onShowHistory;
  final VoidCallback onShowSettings;

  const _ChatHeader({
    required this.onShowHistory,
    required this.onShowSettings,
  });

  static String _compactTokens(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(2)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return value.toString();
  }

  static String _contextUsage(int used, int limit, double ratio) {
    final percent = (ratio * 100).clamp(0, 999).toStringAsFixed(1);
    return '${_compactTokens(used)} / ${AiContextWindowSize.label(limit)} ($percent%)';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _AiStrings(language);

    return Selector<AiChatViewModel, _ChatHeaderSnapshot>(
      selector: (context, vm) {
        final activeChat = vm.activeChat!;
        return _ChatHeaderSnapshot(
          chatId: activeChat.id,
          title: activeChat.title,
          contextTokens: vm.contextTokensFor(activeChat),
          contextWindowTokens: vm.contextWindowTokens,
          sending: vm.sending,
        );
      },
      builder: (context, snapshot, child) {
        final contextPercent = snapshot.contextWindowTokens <= 0
            ? 0.0
            : snapshot.contextTokens / snapshot.contextWindowTokens;

        return ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: strings.history,
                    icon: const Icon(Icons.menu_rounded),
                    onPressed: onShowHistory,
                  ),
                  Expanded(
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey('chat-title-${snapshot.chatId}'),
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) {
                        return Opacity(
                          opacity: value,
                          child: Transform.translate(
                            offset: Offset(12 * (1 - value), 0),
                            child: child,
                          ),
                        );
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          OverflowScrollText(
                            snapshot.title,
                            selectable: false,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          OverflowScrollText(
                            _contextUsage(
                              snapshot.contextTokens,
                              snapshot.contextWindowTokens,
                              contextPercent,
                            ),
                            selectable: false,
                            maxLines: 1,
                            style: TextStyle(
                              color:
                                  colorScheme.onSurface.withValues(alpha: 0.62),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: strings.newChat,
                    icon: const Icon(Icons.add_comment_outlined),
                    onPressed: snapshot.sending
                        ? null
                        : () {
                            context
                                .read<AiChatViewModel>()
                                .createChatFromSettings();
                          },
                  ),
                  IconButton(
                    tooltip: strings.settings,
                    icon: const Icon(Icons.tune_rounded),
                    onPressed: onShowSettings,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
