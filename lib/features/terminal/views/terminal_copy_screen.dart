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
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.text);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _textController.dispose();
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
          child: TextField(
            controller: _textController,
            scrollController: _scrollController,
            readOnly: true,
            minLines: null,
            maxLines: null,
            expands: true,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            enableSuggestions: false,
            autocorrect: false,
            style: TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: [
                'Consolas',
                'Microsoft YaHei',
                'PingFang SC',
                'sans-serif'
              ],
              fontSize: 13,
              height: 1.35,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }
}
