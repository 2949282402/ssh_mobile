import 'package:flutter/material.dart';

class TypedConfirmDialog extends StatefulWidget {
  final String title;
  final String content;
  final String requiredText;
  final String cancelLabel;
  final String confirmLabel;

  const TypedConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.requiredText,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String content,
    required String requiredText,
    required String cancelLabel,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => TypedConfirmDialog(
        title: title,
        content: content,
        requiredText: requiredText,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
      ),
    );
    return result ?? false;
  }

  @override
  State<TypedConfirmDialog> createState() => _TypedConfirmDialogState();
}

class _TypedConfirmDialogState extends State<TypedConfirmDialog> {
  late final TextEditingController _controller;

  bool get _matchesRequiredText => _controller.text == widget.requiredText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController()..addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.content),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              helperText: widget.requiredText,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
          onPressed:
              _matchesRequiredText ? () => Navigator.pop(context, true) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
