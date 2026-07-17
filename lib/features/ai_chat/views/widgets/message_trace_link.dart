part of 'message_bubble.dart';

class _AgentTraceLink extends StatelessWidget {
  final String chatId;
  final String runId;
  final AiChatMessageRecord message;

  const _AgentTraceLink({
    required this.chatId,
    required this.runId,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);
    final String label;
    if (message.traces.isNotEmpty) {
      label = [
        strings.trace,
        strings.traceEvents(message.traces.length),
      ].join(' · ');
    } else {
      final shortRunId = runId.length > 8
          ? runId.substring(runId.length - 8)
          : runId;
      label = '${strings.trace} · $shortRunId';
    }

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: 48,
          maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(180.0, 520.0),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    AgentTraceDebugPage(chatId: chatId, runId: runId),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 16,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
