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

  bool get _canSubmit => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText)
      ..selection = TextSelection.collapsed(offset: widget.initialText.length)
      ..addListener(_handleTextChanged);
  }

  void _handleTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final availableHeight =
        mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.padding.vertical;
    final compactHeight = availableHeight < 360;
    final dialogHeight = (availableHeight - (compactHeight ? 8 : 24))
        .clamp(112.0, 640.0)
        .toDouble();
    final actionStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 16),
    );

    return Semantics(
      namesRoute: true,
      label: widget.strings.editMessage,
      child: Dialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: compactHeight ? 4 : 12,
        ),
        child: SizedBox(
          width: 560,
          height: dialogHeight,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compactHeight ? 12 : 20,
              compactHeight ? 8 : 18,
              compactHeight ? 12 : 20,
              compactHeight ? 8 : 16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compactHeight) ...[
                  Text(
                    widget.strings.editMessage,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 14),
                ],
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('edit-message-field'),
                    controller: _controller,
                    autofocus: true,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      labelText: widget.strings.messageContent,
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
                SizedBox(height: compactHeight ? 6 : 14),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      key: const ValueKey<String>('edit-message-cancel'),
                      style: actionStyle,
                      onPressed: () => Navigator.pop(context),
                      child: Text(widget.strings.cancel),
                    ),
                    FilledButton(
                      key: const ValueKey<String>('edit-message-submit'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      onPressed: _canSubmit
                          ? () => Navigator.pop(context, _controller.text)
                          : null,
                      child: Text(widget.strings.saveAndSend),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
