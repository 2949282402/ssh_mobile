part of '../llm_chat_screen.dart';

class _ChatToolApprovalArea extends StatelessWidget {
  const _ChatToolApprovalArea();

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);

    return Selector<AiChatViewModel, _ToolApprovalSnapshot>(
      selector: (context, vm) {
        return _ToolApprovalSnapshot(
          chatId: vm.activeChatId ?? '',
          pendingApproval: vm.pendingApproval,
        );
      },
      builder: (context, snapshot, child) {
        final pending = snapshot.pendingApproval;
        if (pending == null || pending.chatId != snapshot.chatId) {
          return const SizedBox.shrink();
        }

        final mediaQuery = MediaQuery.of(context);
        final compactHeight = usesCompactRailForHeight(mediaQuery.size.height);
        if (compactHeight && mediaQuery.viewInsets.bottom > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            FocusManager.instance.primaryFocus?.unfocus();
          });
          return const SizedBox.shrink();
        }

        final viewModel = context.read<AiChatViewModel>();

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: toolApprovalPanelMaxHeightFor(
              viewportHeight: mediaQuery.size.height,
              compactHeight: compactHeight,
            ),
          ),
          child: ToolApprovalPanel(
            pending: pending,
            strings: strings,
            onApprove: () => viewModel.resolvePendingApproval(approved: true),
            onReject: () => viewModel.resolvePendingApproval(approved: false),
          ),
        );
      },
    );
  }
}
