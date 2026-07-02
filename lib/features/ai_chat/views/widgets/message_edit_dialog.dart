part of 'message_bubble.dart';

class EditUserMessageDialog extends StatefulWidget {
  final String initialText;
  final AiStrings strings;

  const EditUserMessageDialog({
    super.key,
    required this.initialText,
    required this.strings,
  });

  @override
  State<EditUserMessageDialog> createState() => EditUserMessageDialogState();
}

class EditUserMessageDialogState extends State<EditUserMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.strings.editMessage),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.strings.saveAndSend),
        ),
      ],
    );
  }
}
