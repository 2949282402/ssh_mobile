import 'package:flutter/material.dart';

class DestructiveConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String cancelLabel;
  final String confirmLabel;

  const DestructiveConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String content,
    required String cancelLabel,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => DestructiveConfirmDialog(
        title: title,
        content: content,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
