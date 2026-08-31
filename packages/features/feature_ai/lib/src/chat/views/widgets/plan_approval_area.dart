part of '../llm_chat_screen.dart';

class ChatPlanApprovalActions extends StatelessWidget {
  final AiStrings strings;
  final DateTime assistantCreatedAt;
  final bool busy;
  final VoidCallback? onApprove;
  final VoidCallback? onRevise;

  const ChatPlanApprovalActions({
    super.key,
    required this.strings,
    required this.assistantCreatedAt,
    required this.busy,
    required this.onApprove,
    required this.onRevise,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final actionSuffix = assistantCreatedAt.microsecondsSinceEpoch;
    final scaledLabelHeight = MediaQuery.textScalerOf(context).scale(14);
    final compactTextLayout = scaledLabelHeight > 18;
    final stacked = MediaQuery.sizeOf(context).width < 400 || compactTextLayout;
    final approve = FilledButton.icon(
      key: ValueKey<String>('plan-approve-$actionSuffix'),
      onPressed: busy ? null : onApprove,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_arrow_rounded, size: 20),
      label: Text(
        strings.approveAndExecutePlan,
        textAlign: TextAlign.center,
        maxLines: 2,
      ),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    );
    final revise = OutlinedButton.icon(
      key: ValueKey<String>('plan-revise-$actionSuffix'),
      onPressed: busy ? null : onRevise,
      icon: const Icon(Icons.edit_note_rounded, size: 20),
      label: Text(
        strings.todoRevisePlan,
        textAlign: TextAlign.center,
        maxLines: 2,
      ),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    );
    final actions = KeyedSubtree(
      key: const ValueKey<String>('plan-approval-actions'),
      child: stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [approve, const SizedBox(height: 8), revise],
            )
          : Row(
              children: [
                Expanded(child: revise),
                const SizedBox(width: 8),
                Expanded(child: approve),
              ],
            ),
    );
    return Semantics(
      key: const ValueKey<String>('plan-approval-area'),
      container: true,
      liveRegion: busy,
      label: busy ? strings.planApprovalChecking : strings.planApprovalHint,
      child: IntrinsicHeight(
        child: Material(
          key: ValueKey<String>('plan-approval-surface-$busy'),
          color: colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.8),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compactTextLayout) ...[
                  Row(
                    key: const ValueKey<String>('plan-approval-header'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.fact_check_outlined,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          busy
                              ? strings.planApprovalChecking
                              : strings.planApprovalHint,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatPlanApprovalArea extends StatelessWidget {
  final double availableHeight;
  final double availableWidth;
  final TextEditingController inputController;
  final bool toolsExpanded;
  final bool uiBusy;
  final void Function(DateTime assistantCreatedAt) onApprove;
  final void Function(AiChatRecord chat) onRevise;

  const _ChatPlanApprovalArea({
    required this.availableHeight,
    required this.availableWidth,
    required this.inputController,
    required this.toolsExpanded,
    required this.uiBusy,
    required this.onApprove,
    required this.onRevise,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final textScale = mediaQuery.textScaler.scale(14) / 14;
    if (!shouldShowPlanApprovalForAvailableHeight(
      availableHeight: availableHeight,
      availableWidth: availableWidth,
      textScale: textScale,
    )) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: inputController,
      builder: (context, inputValue, child) {
        if (toolsExpanded || inputValue.text.isNotEmpty) {
          return const SizedBox.shrink();
        }
        final language = context.select<AppSettings, AppLanguage>(
          (settings) => settings.language,
        );
        final strings = AiStrings(language);
        return Consumer<AiChatViewModel>(
          builder: (context, viewModel, child) {
            final chat = viewModel.activeChat;
            final plan = chat == null
                ? null
                : approvablePlanMessageForChat(chat);
            if (chat == null ||
                plan == null ||
                viewModel.sending ||
                viewModel.pendingAttachments.isNotEmpty) {
              return const SizedBox.shrink();
            }

            final eligibleChat = chat;
            final eligiblePlan = plan;
            final busy = uiBusy || viewModel.planApprovalInFlight;
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Align(
                alignment: Alignment.center,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: ChatPlanApprovalActions(
                    strings: strings,
                    assistantCreatedAt: eligiblePlan.createdAt,
                    busy: busy,
                    onApprove: busy
                        ? null
                        : () => onApprove(eligiblePlan.createdAt),
                    onRevise: busy ? null : () => onRevise(eligibleChat),
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
