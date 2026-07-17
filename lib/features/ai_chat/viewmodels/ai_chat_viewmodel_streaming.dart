part of 'ai_chat_viewmodel.dart';

extension AiChatStreamingState on AiChatViewModel {
  void _beginStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required String status,
  }) {
    _streamingAssistantTarget = _StreamingAssistantTarget(
      chatId: chatId,
      assistantCreatedAt: assistantCreatedAt,
    );
    streamingAssistantText.value = '';
    streamingAssistantStatus.value = status;
  }

  void _updateStreamingAssistant(String text) {
    if (streamingAssistantText.value == text) return;
    streamingAssistantText.value = text;
  }

  void _updateStreamingAssistantStatus(String status) {
    if (_streamingAssistantTarget == null) return;
    if (streamingAssistantStatus.value == status) return;
    streamingAssistantStatus.value = status;
  }

  void _clearStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
  }) {
    final target = _streamingAssistantTarget;
    if (target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != assistantCreatedAt) {
      return;
    }
    _streamingAssistantTarget = null;
    streamingAssistantText.value = '';
    streamingAssistantStatus.value = '';
  }

  void _appendTraceToAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required LlmTraceEvent event,
  }) {
    final currentChat = _chatById(chatId);
    if (currentChat == null) return;
    final messages = [...currentChat.messages];
    final assistantIndex = messages.indexWhere(
      (message) =>
          message.role == 'assistant' &&
          message.createdAt == assistantCreatedAt,
    );
    if (assistantIndex < 0) return;
    messages[assistantIndex] = messages[assistantIndex].copyWith(
      traces: [
        ...messages[assistantIndex].traces,
        AiMessageTrace.create(
          kind: event.kind,
          title: AiChatViewModel._traceSecretPolicy.redactText(event.title),
          content: AiChatViewModel._traceSecretPolicy.redactJsonText(
            event.content,
          ),
        ),
      ],
    );
    _replaceChat(
      currentChat.copyWith(messages: messages, updatedAt: DateTime.now()),
      sort: false,
      activate: false,
    );
    notify();
    _triggerScroll();
  }

  List<AiMessageTrace> _ensureAgentRunSummaryTrace(
    List<AiMessageTrace> traces,
    String finalOutcome, {
    LlmRunStats? runStats,
  }) {
    for (final trace in traces.reversed) {
      if (trace.kind != 'agent_run_summary') continue;
      try {
        final decoded = jsonDecode(trace.content);
        if (decoded is Map &&
            '${decoded['finalOutcome'] ?? decoded['outcome'] ?? ''}'
                .trim()
                .isNotEmpty) {
          return List<AiMessageTrace>.from(traces, growable: false);
        }
      } catch (_) {
        continue;
      }
    }
    return [
      ...traces,
      AiMessageTrace.create(
        kind: 'agent_run_summary',
        title: 'Agent run summary',
        content: jsonEncode({
          'finalOutcome': finalOutcome,
          if (runStats != null) ...{
            'toolCalls': runStats.toolCalls,
            'approvalCount': runStats.approvalCount,
            'approvedCount': runStats.approvedCount,
            'elapsedMs': runStats.elapsedMs,
          },
        }),
      ),
    ];
  }

  bool _consumeContextCompression(String chatId) {
    return _pendingForceCompressionChats.remove(chatId);
  }

  // 内部辅助，从Slash命令提取
}
