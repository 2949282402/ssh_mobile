part of '../llm_chat_screen.dart';

class _HistoryPanel extends StatefulWidget {
  final List<AiChatRecord> chats;
  final String? activeChatId;
  final bool loading;
  final _AiStrings strings;
  final String Function(DateTime time) formatTime;
  final VoidCallback onClose;
  final VoidCallback onNewChat;
  final ValueChanged<String> onSelectChat;
  final Future<void> Function(AiChatRecord chat) onDeleteChat;

  const _HistoryPanel({
    required this.chats,
    required this.activeChatId,
    required this.loading,
    required this.strings,
    required this.formatTime,
    required this.onClose,
    required this.onNewChat,
    required this.onSelectChat,
    required this.onDeleteChat,
  });

  @override
  State<_HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<_HistoryPanel> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<AiChatRecord> get _filteredChats {
    if (_searchQuery.isEmpty) return widget.chats;
    final query = _searchQuery.toLowerCase();
    return widget.chats.where((chat) {
      if (chat.title.toLowerCase().contains(query)) {
        return true;
      }
      return chat.messages.any((message) {
        final text = message.text.toLowerCase();
        if (text.contains(query)) return true;
        final contextText = message.contextText;
        return contextText != null && contextText.toLowerCase().contains(query);
      });
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final filtered = _filteredChats;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: widget.strings.close,
                icon: const Icon(Icons.close_rounded),
                onPressed: widget.onClose,
              ),
              Expanded(
                child: Text(
                  widget.strings.history,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: widget.strings.newChat,
                icon: const Icon(Icons.add_rounded),
                onPressed: widget.onNewChat,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchQuery = value),
            decoration: InputDecoration(
              hintText: widget.strings.language == AppLanguage.en
                  ? 'Search history'
                  : '搜索历史记录',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        Expanded(
          child: widget.loading
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : filtered.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isNotEmpty
                            ? (widget.strings.language == AppLanguage.en
                                ? 'No results'
                                : '无搜索结果')
                            : (widget.strings.language == AppLanguage.en
                                ? 'No history'
                                : '暂无历史记录'),
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final chat = filtered[index];
                        final selected = chat.id == widget.activeChatId;
                        return ListTile(
                          selected: selected,
                          leading: Icon(
                            selected
                                ? Icons.chat_bubble_rounded
                                : Icons.chat_bubble_outline_rounded,
                            color: selected ? colorScheme.primary : null,
                          ),
                          title: OverflowScrollText(
                            chat.title,
                            selectable: false,
                            maxLines: 1,
                          ),
                          subtitle: OverflowScrollText(
                            widget.formatTime(chat.updatedAt),
                            selectable: false,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  colorScheme.onSurface.withValues(alpha: 0.58),
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: widget.strings.delete,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => widget.onDeleteChat(chat),
                          ),
                          onTap: () => widget.onSelectChat(chat.id),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

extension _LlmChatScreenBodyStateHistory on _LlmChatScreenBodyState {
  Future<void> _showHistory(BuildContext context, _AiStrings strings) async {
    _openHistoryPanel(context);
    final viewModel = context.read<AiChatViewModel>();
    unawaited(viewModel.loadHistoryChatsIfNeeded());
  }

  double _historyPanelWidth(BuildContext context) {
    return MediaQuery.sizeOf(context).width;
  }

  void _openHistoryPanel(BuildContext context) {
    final viewModel = context.read<AiChatViewModel>();
    _animateHistoryPanel(context, _historyPanelWidth(context));
    unawaited(viewModel.loadHistoryChatsIfNeeded());
  }

  void _closeHistoryPanel(BuildContext context) {
    _animateHistoryPanel(context, 0);
  }

  void _animateHistoryPanel(BuildContext context, double target) {
    final width = _historyPanelWidth(context);
    final safeTarget = target.clamp(0.0, width);
    _historySlideAnimation = Tween<double>(
      begin: _historyPanelExtent.value.clamp(0.0, width),
      end: safeTarget,
    ).animate(
      CurvedAnimation(
        parent: _historySlideController,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );
    _historySlideController.forward(from: 0);
  }

  void _setHistoryPanelExtent(double extent) {
    if ((_historyPanelExtent.value - extent).abs() < 0.5) return;
    final wasVisible = _historyPanelExtent.value > 0.5;
    _historyPanelExtent.value = extent;
    final isVisible = extent > 0.5;
    if (wasVisible != isVisible) {
      widget.onHistoryVisibilityChanged?.call(isVisible);
    }
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}
