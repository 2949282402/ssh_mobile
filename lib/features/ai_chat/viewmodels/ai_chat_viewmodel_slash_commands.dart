part of 'ai_chat_viewmodel.dart';

extension AiChatViewModelSlashCommands on AiChatViewModel {
  Future<SendTextResult?> _executeSlashCommand({
    required String chatId,
    required String input,
  }) async {
    final parts = input.split(' ');
    final cmd = parts[0].toLowerCase();
    final args = parts.sublist(1).join(' ').trim();
    final activeChat = this.activeChat;
    if (activeChat == null) return null;

    final isEn = _appSettings.language == AppLanguage.en;

    if (cmd == '/compact') {
      _pendingForceCompressionChats.add(chatId);
      return SendTextSlashCommandHandled(
        isEn
            ? 'Forced context compaction scheduled for the next generation.'
            : '已强制计划在下一次生成时对上下文进行压缩。',
      );
    }

    if (cmd == '/plan') {
      final updated = activeChat.copyWith(
        planMode: true,
        updatedAt: DateTime.now(),
      );
      _replaceChat(updated);
      notify();
      await _storageService.saveAiChat(updated);
      return SendTextSlashCommandHandled(
        isEn
            ? 'Plan Mode Enabled. Helper agents will analyze read-only details and prepare a structured execution plan.'
            : '规划模式已启用。多 Agent 协作将仅执行只读信息收集并生成结构化执行计划。',
      );
    }

    if (cmd == '/tools') {
      final tools = _parseToolList(args);
      if (tools.isEmpty) {
        final service = _runtimeFactory.createToolService(chatId: chatId);
        final definitions = await service.toolDefinitions();
        final names = definitions
            .map((def) => _toolNameFromDefinition(def))
            .nonNulls
            .where((name) => name.isNotEmpty)
            .toList();
        return SendTextSlashCommandOpenToolsSelector(
          availableTools: names,
          currentAllowedTools: _chatAllowedTools[chatId] ?? const {},
        );
      } else {
        final nextAllowed = Set<String>.from(tools);
        _chatAllowedTools[chatId] = nextAllowed;
        notify();
        return SendTextSlashCommandHandled(
          isEn
              ? 'Restricted active toolset to: ${tools.join(", ")}'
              : '已限制当前对话的工具调用范围为: ${tools.join(", ")}',
        );
      }
    }

    if (cmd == '/skills') {
      return const SendTextSlashCommandOpenSkills();
    }

    return null;
  }

  List<String> _parseToolList(String text) {
    return text
        .split(RegExp(r'[,\s]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Future<List<Map<String, dynamic>>> loadToolDefinitions() async {
    final service = _runtimeFactory.createToolService(chatId: _activeChatId);
    return await service.toolDefinitions();
  }

  String? _toolNameFromDefinition(Map<String, dynamic> definition) {
    final function = definition['function'];
    if (function is! Map) return null;
    final name = function['name'];
    return name is String ? name : null;
  }
}
