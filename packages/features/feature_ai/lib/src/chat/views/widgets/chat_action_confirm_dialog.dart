part of '../llm_chat_screen.dart';

Future<bool> showChatActionConfirmation({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required AiStrings strings,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  final result = await showDialog<bool>(
    context: context,
    useSafeArea: true,
    builder: (context) => ChatActionConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      strings: strings,
    ),
  );
  return result == true;
}

class ChatActionConfirmDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final AiStrings strings;

  const ChatActionConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.strings,
  });

  @override
  State<ChatActionConfirmDialog> createState() =>
      _ChatActionConfirmDialogState();
}

class _ChatActionConfirmDialogState extends State<ChatActionConfirmDialog> {
  bool _closing = false;

  void _close(bool confirmed) {
    if (_closing || !mounted) return;
    setState(() => _closing = true);
    Navigator.of(context).pop(confirmed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('chat-action-confirm-dialog'),
      scrollable: true,
      constraints: const BoxConstraints(maxWidth: 520),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title: Text(widget.title),
      content: Text(widget.message),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      actionsOverflowButtonSpacing: 8,
      actions: [
        SizedBox(
          key: const ValueKey('chat-action-cancel'),
          height: 48,
          child: TextButton(
            onPressed: _closing ? null : () => _close(false),
            child: Text(widget.strings.cancel),
          ),
        ),
        SizedBox(
          key: const ValueKey('chat-action-confirm'),
          height: 48,
          child: FilledButton(
            onPressed: _closing ? null : () => _close(true),
            child: Text(widget.confirmLabel),
          ),
        ),
      ],
    );
  }
}
