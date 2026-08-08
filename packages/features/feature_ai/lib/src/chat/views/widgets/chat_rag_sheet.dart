part of '../llm_chat_screen.dart';

class ChatRagSheet {
  static Future<void> show(BuildContext context, AiStrings strings) async {
    final appSettings = context.read<AppSettings>();
    final viewModel = context.read<AiChatViewModel>();
    final aliyunKey = await viewModel.getAliyunApiKey();
    final hasAliyunKey = aliyunKey != null && aliyunKey.isNotEmpty;

    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => ChatRagSheetContent(
        strings: strings,
        appSettings: appSettings,
        hasAliyunKey: hasAliyunKey,
        onManage: () {
          final navigator = Navigator.of(sheetContext);
          navigator.pop();
          unawaited(navigator.pushNamed('/rag-knowledge'));
        },
      ),
    );
  }
}

class ChatRagSheetContent extends StatefulWidget {
  const ChatRagSheetContent({
    super.key,
    required this.strings,
    required this.appSettings,
    required this.hasAliyunKey,
    required this.onManage,
  });

  final AiStrings strings;
  final AppSettings appSettings;
  final bool hasAliyunKey;
  final VoidCallback onManage;

  @override
  State<ChatRagSheetContent> createState() => _ChatRagSheetContentState();
}

class _ChatRagSheetContentState extends State<ChatRagSheetContent> {
  Future<void> _setRagEnabled(bool value) async {
    await widget.appSettings.setRagEnabled(value);
    if (mounted) setState(() {});
  }

  Future<void> _setSearchMode(String? value) async {
    if (value == null) return;
    await widget.appSettings.setRagSearchMode(value);
    if (mounted) setState(() {});
  }

  Future<void> _setTopN(int? value) async {
    if (value == null) return;
    await widget.appSettings.setRagTopN(value);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = widget.strings;
    final ragEnabled = widget.appSettings.ragEnabled;
    final searchMode = widget.appSettings.ragSearchMode;
    final topN = widget.appSettings.ragTopN;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const AppIconBadge(
                    icon: Icons.auto_stories_outlined,
                    size: 36,
                    iconSize: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      strings.ragSettings,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('chat-rag-close'),
                    tooltip: strings.close,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SwitchListTile.adaptive(
                key: const ValueKey<String>('chat-rag-enabled'),
                contentPadding: EdgeInsets.zero,
                title: Text(strings.ragTitle),
                subtitle: Text(strings.ragHint),
                value: ragEnabled,
                onChanged: _setRagEnabled,
              ),
              if (ragEnabled) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey<String>('chat-rag-mode'),
                  initialValue: searchMode,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: strings.ragSearchMode),
                  selectedItemBuilder: (context) => [
                    for (final value in const ['bm25', 'vector', 'hybrid'])
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _searchModeLabel(strings, value),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  items: [
                    for (final value in const ['bm25', 'vector', 'hybrid'])
                      DropdownMenuItem<String>(
                        value: value,
                        child: Text(
                          _searchModeLabel(strings, value),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _setSearchMode,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<int>(
                  key: const ValueKey<String>('chat-rag-top-n'),
                  initialValue: topN,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: strings.ragTopN),
                  items: [
                    for (final value in const [1, 2, 3, 4, 5, 6, 8, 10])
                      DropdownMenuItem<int>(
                        value: value,
                        child: Text(
                          strings.ragTopNValue(value),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _setTopN,
                ),
                if ((searchMode == 'vector' || searchMode == 'hybrid') &&
                    !widget.hasAliyunKey) ...[
                  const SizedBox(height: 10),
                  Text(
                    strings.ragSearchModeNeedKey,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                key: const ValueKey<String>('chat-rag-manage'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                icon: const Icon(Icons.folder_shared_outlined),
                label: Text(strings.ragManage),
                onPressed: widget.onManage,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _searchModeLabel(AiStrings strings, String value) {
    return switch (value) {
      'vector' => strings.ragSearchModeVector,
      'hybrid' => strings.ragSearchModeHybrid,
      _ => strings.ragSearchModeBm25,
    };
  }
}
