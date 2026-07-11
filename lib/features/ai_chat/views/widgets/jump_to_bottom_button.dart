part of '../llm_chat_screen.dart';

class _ChatJumpToBottomButton extends StatelessWidget {
  final ScrollController scrollController;
  final ValueNotifier<bool> isUserAtBottom;
  final VoidCallback onPressed;

  const _ChatJumpToBottomButton({
    required this.scrollController,
    required this.isUserAtBottom,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final sending = context.select<AiChatViewModel, bool>((vm) => vm.sending);

    if (!sending) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: isUserAtBottom,
      builder: (context, atBottom, _) {
        if (atBottom) return const SizedBox.shrink();
        if (!scrollController.hasClients) return const SizedBox.shrink();
        if (scrollController.position.maxScrollExtent <= 48) {
          return const SizedBox.shrink();
        }

        return Positioned(
          right: 14,
          bottom: 12,
          child: FloatingActionButton.small(
            onPressed: onPressed,
            child: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
        );
      },
    );
  }
}
