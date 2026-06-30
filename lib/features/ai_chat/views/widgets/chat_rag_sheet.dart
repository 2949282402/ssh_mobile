part of '../llm_chat_screen.dart';

extension _ChatRagSheet on _LlmChatScreenBodyState {
  Future<void> _showRagBottomSheet(
      BuildContext context, _AiStrings strings) async {
    final appSettings = context.read<AppSettings>();
    final viewModel = context.read<AiChatViewModel>();
    final aliyunKey = await viewModel.getAliyunApiKey();
    final hasAliyunKey = aliyunKey != null && aliyunKey.isNotEmpty;

    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final theme = Theme.of(context);
          final ragEnabled = appSettings.ragEnabled;
          final searchMode = appSettings.ragSearchMode;
          final topN = appSettings.ragTopN;

          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.auto_stories,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            strings.ragTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const Divider(),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.ragTitle),
                    subtitle: Text(strings.ragHint),
                    value: ragEnabled,
                    onChanged: (value) async {
                      await appSettings.setRagEnabled(value);
                      setState(() {});
                    },
                  ),
                  if (ragEnabled) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: searchMode,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: strings.ragSearchMode,
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'bm25',
                          child: Text(strings.ragSearchModeBm25),
                        ),
                        DropdownMenuItem(
                          value: 'vector',
                          child: Text(strings.ragSearchModeVector),
                        ),
                        DropdownMenuItem(
                          value: 'hybrid',
                          child: Text(strings.ragSearchModeHybrid),
                        ),
                      ],
                      onChanged: (value) async {
                        if (value != null) {
                          await appSettings.setRagSearchMode(value);
                          setState(() {});
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<int>(
                      initialValue: topN,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: strings.ragTopN,
                        isDense: true,
                      ),
                      items: [
                        for (final value in [1, 2, 3, 4, 5, 6, 8, 10])
                          DropdownMenuItem(
                            value: value,
                            child: Text(strings.ragTopNValue(value)),
                          ),
                      ],
                      onChanged: (value) async {
                        if (value != null) {
                          await appSettings.setRagTopN(value);
                          setState(() {});
                        }
                      },
                    ),
                    if ((searchMode == 'vector' || searchMode == 'hybrid') &&
                        !hasAliyunKey) ...[
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
                  ElevatedButton.icon(
                    icon: const Icon(Icons.folder_shared_outlined),
                    label: Text(strings.ragManage),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.pushNamed(context, '/rag-knowledge');
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
