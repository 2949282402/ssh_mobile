import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';

class WindowNameDialog extends StatefulWidget {
  final String initialName;
  final bool Function(String name) isNameAvailable;

  const WindowNameDialog({
    super.key,
    required this.initialName,
    required this.isNameAvailable,
  });

  @override
  State<WindowNameDialog> createState() => _WindowNameDialogState();
}

class _WindowNameDialogState extends State<WindowNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final name = _controller.text.trim();
    final valid = widget.isNameAvailable(name);
    return AlertDialog(
      title: Text(strings.newTerminalWindow),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: strings.windowName,
          errorText: name.isEmpty
              ? strings.enterWindowName
              : valid
                  ? null
                  : strings.duplicateWindowName,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (valid) Navigator.pop(context, name);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        TextButton(
          onPressed: valid ? () => Navigator.pop(context, name) : null,
          child: Text(strings.create),
        ),
      ],
    );
  }
}
