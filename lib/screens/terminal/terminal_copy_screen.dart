import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TerminalCopyScreen extends StatelessWidget {
  final String title;
  final String text;
  final String copyAllTooltip;

  const TerminalCopyScreen({
    super.key,
    required this.title,
    required this.text,
    required this.copyAllTooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: copyAllTooltip,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
