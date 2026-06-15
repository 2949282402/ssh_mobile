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
    final lastUserIndex =
        messages.lastIndexWhere((message) => message['role'] == 'user');
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
    final response = await _chatCompletion(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      messages: [
        {
          'role': 'system',
          'content': compressionPrompt,
        },
        {'role': 'user', 'content': transcript},
      ],
      deepSeekThinkingEnabled: deepSeekThinkingEnabled,
      deepSeekReasoningEffort: deepSeekReasoningEffort,
      openAiReasoningEffort: openAiReasoningEffort,
      cancellationToken: cancellationToken,
      operationLabel: 'LLM compression',
    );
    cancellationToken?.throwIfCancelled();
    final summary = _contentFromChatResponse(response);
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

  Future<Map<String, dynamic>> _chatCompletion({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
    bool includeReasoningParams = true,
    LlmCancellationToken? cancellationToken,
    String operationLabel = 'LLM completion',
  }) async {
    final endpoint = Uri.parse(_joinUrl(baseUrl, '/chat/completions'));
    cancellationToken?.throwIfCancelled();
    for (var attempt = 0;
        attempt <= LlmChatService._networkRetryCount;
        attempt++) {
      final client = HttpClient();
      cancellationToken?.onCancel(() => client.close(force: true));
      try {
        final request = await client.postUrl(endpoint);
        final requestBody = <String, dynamic>{
          'model': model,
          'messages': messages,
        };
        if (includeReasoningParams) {
          requestBody.addAll(
            _providerReasoningParams(
              baseUrl: baseUrl,
              model: model,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
            ),
          );
        }
        final bodyBytes = utf8.encode(jsonEncode(requestBody));
        request.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
          ..contentType = ContentType.json;
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (includeReasoningParams &&
              response.statusCode == 400 &&
              _looksLikeReasoningParamUnsupportedError(body)) {
            AppLogService.instance.warning(
              '$operationLabel reasoning params unsupported, retrying without them',
              details:
                  'endpoint=$endpoint model=$model bodyChars=${body.length}',
            );
            return _chatCompletion(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              messages: messages,
              deepSeekThinkingEnabled: deepSeekThinkingEnabled,
              deepSeekReasoningEffort: deepSeekReasoningEffort,
              openAiReasoningEffort: openAiReasoningEffort,
              includeReasoningParams: false,
              cancellationToken: cancellationToken,
              operationLabel: operationLabel,
            );
          }
          throw StateError(
            '$operationLabel failed (${response.statusCode}): $body',
          );
        }
        return jsonDecode(body) as Map<String, dynamic>;
      } catch (e, stackTrace) {
        if (cancellationToken?.isCancelled == true) {
          throw const LlmCancelledException();
        }
        final canRetry = _isRetryableNetworkError(e) &&
            attempt < LlmChatService._networkRetryCount;
        if (canRetry) {
          AppLogService.instance.warning(
            '$operationLabel network error, retrying',
            details:
                'endpoint=$endpoint model=$model attempt=${attempt + 1} nextAttempt=${attempt + 2} error=$e stack=$stackTrace',
          );
          await _delayBeforeNetworkRetry(attempt, cancellationToken);
          continue;
        }
        AppLogService.instance.error(
          '$operationLabel request error',
          error: e,
          stackTrace: stackTrace,
          details: 'endpoint=$endpoint model=$model attempt=${attempt + 1}',
        );
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('$operationLabel failed after network retries.');
  }

  String _contentFromChatResponse(Map<String, dynamic> response) {
    final choices = response['choices'];
    if (choices is List && choices.isNotEmpty) {
      final message = (choices.first as Map)['message'];
      if (message is Map && message['content'] is String) {
        return message['content'] as String;
      }
    }
    return 'No prior context summary was returned.';
  }
}

// Token estimation functions
int _estimateMessagesTokens(List<Map<String, dynamic>> messages) {
  var total = 0;
  for (final message in messages) {
    total += 4;
    total += _estimateTextTokens('${message['role'] ?? ''}');
    total += _estimateTextTokens('${message['content'] ?? ''}');
  }
  return total;
}

/// 简单的 Token 估算：ASCII 4 字符 = 1 token，非 ASCII = 1 token 每个字符
/// 精确度约 80-85%，不依赖 tiktoken（Dart 生态不成熟）
int _estimateTextTokens(String text) {
  if (text.isEmpty) return 0;
  var asciiRunes = 0;
  var nonAsciiRunes = 0;
  for (final rune in text.runes) {
    if (rune <= 0x7f) {
      asciiRunes++;
    } else {
      nonAsciiRunes++;
    }
  }
  return (asciiRunes / 4).ceil() + nonAsciiRunes;
}
