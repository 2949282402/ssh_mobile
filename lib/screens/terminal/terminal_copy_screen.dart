import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TerminalCopyScreen extends StatefulWidget {
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
  State<TerminalCopyScreen> createState() => _TerminalCopyScreenState();
}

class _TerminalCopyScreenState extends State<TerminalCopyScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: widget.copyAllTooltip,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.text));
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SelectionArea(
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              widget.text,
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
