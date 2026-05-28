part of '../llm_chat_screen.dart';

final ValueNotifier<String> _emptyStringListenable = ValueNotifier<String>('');

class _AssistantRunIndicator extends StatelessWidget {
  final String label;
  final bool compact;

  const _AssistantRunIndicator({
    required this.label,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
          height: 1.2,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: compact ? 13 : 15,
          height: compact ? 13 : 15,
          child: CircularProgressIndicator(
            strokeWidth: compact ? 1.8 : 2,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: textStyle,
          ),
        ),
      ],
    );
  }
}
