part of '../llm_chat_screen.dart';

final ValueNotifier<String> emptyStringListenable = ValueNotifier<String>('');

class AssistantRunIndicator extends StatelessWidget {
  final String label;
  final bool compact;

  const AssistantRunIndicator({
    super.key,
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
        AppLoadingIndicator(
          size: compact ? 13 : 15,
          strokeWidth: compact ? 1.8 : 2,
          color: colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Flexible(child: Text(label, style: textStyle)),
      ],
    );
  }
}
