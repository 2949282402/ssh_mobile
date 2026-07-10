part of '../llm_chat_service.dart';

/// Context compression extension for [LlmChatService].
extension LlmContextCompressor on LlmChatService {
  /// 将除最后一条 user 消息外的历史发给 LLM 做摘要，
  /// 保留服务器名、路径、命令、决策等关键操作信息。
  Future<List<Map<String, dynamic>>> _compressWorkingMessages({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required int contextWindowTokens,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
    LlmCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final lastUserIndex = messages.lastIndexWhere(
      (message) => message['role'] == 'user',
    );
    if (lastUserIndex <= 0) {
      return [
        {'role': 'system', 'content': systemPrompt},
        ...messages,
      ];
    }

    final history = messages.take(lastUserIndex).toList();
    final tail = messages.skip(lastUserIndex).toList();
    final transcript = history
        .map((message) => '${message['role']}: ${message['content'] ?? ''}')
        .join('\n\n');
    AppLogService.instance.info(
      'LLM context compression started',
      details:
          'historyMessages=${history.length} estimatedTokens=${LlmChatService.estimateTextTokens(transcript)} window=$contextWindowTokens',
    );
    final settings = await storageService.loadAiConnectionSettings();
    final provider = LlmProviderFactory.fromSettings(settings);
    final response = await provider.complete(
      LlmProviderRequest(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        messages: [
          {'role': 'system', 'content': compressionPrompt},
          {'role': 'user', 'content': transcript},
        ],
        deepSeekThinkingEnabled: deepSeekThinkingEnabled,
        deepSeekReasoningEffort: deepSeekReasoningEffort,
        openAiReasoningEffort: openAiReasoningEffort,
        cancellationToken: cancellationToken,
        timeoutSeconds: settings.timeoutSeconds,
      ),
    );
    cancellationToken?.throwIfCancelled();
    final summary = response.text;
    AppLogService.instance.info(
      'LLM context compression completed',
      details:
          'summaryTokens=${LlmChatService.estimateTextTokens(summary)} tailMessages=${tail.length}',
    );
    return [
      {'role': 'system', 'content': systemPrompt},
      {
        'role': 'assistant',
        'content': '$conversationMemorySummaryHeader$summary',
      },
      ...tail,
    ];
  }
}
