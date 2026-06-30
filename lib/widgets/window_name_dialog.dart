import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
    final errorText = name.isEmpty
        ? strings.enterWindowName
        : valid
            ? null
            : strings.duplicateWindowName;

    return ShadDialog(
      title: Text(strings.newTerminalWindow),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        ShadButton(
          onPressed: valid ? () => Navigator.pop(context, name) : null,
          child: Text(strings.create),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShadInput(
            controller: _controller,
            autofocus: true,
            placeholder: Text(strings.windowName),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (valid) Navigator.pop(context, name);
            },
          ),
          if (errorText != null) ...[
            const SizedBox(height: 6),
            Text(
              errorText,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
