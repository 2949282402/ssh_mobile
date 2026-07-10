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
    final String label;
    if (message.traces.isNotEmpty) {
      final tools = message.traces
          .where((trace) => trace.kind.contains('tool'))
          .length;
      final approvals = message.traces
          .where((trace) => trace.kind.contains('approval'))
          .length;
      final elapsed = message.elapsedMs == null
          ? null
          : _formatElapsedForTraceLink(message.elapsedMs!);
      label = [
        'Trace',
        '${message.traces.length} events',
        if (tools > 0) '$tools tools',
        if (approvals > 0) '$approvals approvals',
        ?elapsed,
      ].join(' · ');
    } else {
      final shortRunId = runId.length > 8
          ? runId.substring(runId.length - 8)
          : runId;
      label = 'Trace · $shortRunId';
    }

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AgentTraceDebugPage(chatId: chatId, runId: runId),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 14,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatElapsedForTraceLink(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}
