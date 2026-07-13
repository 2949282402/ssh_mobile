part of '../llm_chat_screen.dart';

class ChatJumpToBottomButton extends StatefulWidget {
  final ScrollController scrollController;
  final ValueNotifier<bool> isUserAtBottom;
  final VoidCallback onPressed;
  final AiStrings strings;

  const ChatJumpToBottomButton({
    super.key,
    required this.scrollController,
    required this.isUserAtBottom,
    required this.onPressed,
    required this.strings,
  });

  @override
  State<ChatJumpToBottomButton> createState() => _ChatJumpToBottomButtonState();
}

class _ChatJumpToBottomButtonState extends State<ChatJumpToBottomButton> {
  bool _layoutCheckScheduled = false;
  int _layoutCheckAttempts = 0;

  void _scheduleLayoutCheck() {
    if (_layoutCheckScheduled) return;
    _layoutCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutCheckScheduled = false;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.isUserAtBottom,
      builder: (context, atBottom, _) {
        if (atBottom) {
          _layoutCheckAttempts = 0;
          return const SizedBox.shrink();
        }
        if (!widget.scrollController.hasClients) {
          return const SizedBox.shrink();
        }
        final position = widget.scrollController.position;
        if (!position.hasContentDimensions) {
          if (_layoutCheckAttempts < 3) {
            _layoutCheckAttempts += 1;
            _scheduleLayoutCheck();
          }
          return const SizedBox.shrink();
        }
        _layoutCheckAttempts = 0;
        if (position.maxScrollExtent <= 48) {
          return const SizedBox.shrink();
        }

        final media = MediaQuery.of(context);
        final colorScheme = Theme.of(context).colorScheme;
        return Positioned(
          right: 12 + media.padding.right,
          bottom: 12,
          child: Tooltip(
            message: widget.strings.jumpToLatestMessage,
            excludeFromSemantics: true,
            child: Semantics(
              key: const ValueKey('chat-jump-to-bottom'),
              container: true,
              button: true,
              label: widget.strings.jumpToLatestMessage,
              onTap: widget.onPressed,
              child: ExcludeSemantics(
                child: Material(
                  color: colorScheme.surfaceContainerHigh,
                  elevation: 3,
                  shadowColor: colorScheme.shadow.withValues(alpha: 0.2),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.onPressed,
                    customBorder: const CircleBorder(),
                    child: SizedBox.square(
                      dimension: 48,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
