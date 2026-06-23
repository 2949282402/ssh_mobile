import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_log_service.dart';
import '../llm_runtime/llm_runtime_types.dart';
import 'llm_provider_adapter.dart';
import 'llm_provider_types.dart';
import 'llm_url_utils.dart';

class _StreamingAnthropicToolCall {
  String id;
  String name;
  final StringBuffer inputJsonBuffer = StringBuffer();

  _StreamingAnthropicToolCall({required this.id, required this.name});
}

class AnthropicMessagesProvider implements LlmProviderAdapter {
  const AnthropicMessagesProvider();

  @override
  Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('API key is not configured.');
    }
    _assertValidHeaderApiKey(apiKey);

    final endpoint = Uri.parse(_joinUrl(baseUrl, '/v1/models'));
    final client = HttpClient();
    final startedAt = DateTime.now();
    AppLogService.instance.info(
      'Anthropic models request sent',
      details: 'endpoint=$endpoint',
    );
    try {
      final request = await client.getUrl(endpoint).timeout(
            const Duration(seconds: 30),
          );
      request.headers
        ..set('x-api-key', apiKey)
        ..set('anthropic-version', '2023-06-01');
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        AppLogService.instance.warning(
          'Anthropic models request failed',
          details: 'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
        );
        throw StateError(
          'Fetch models failed (${response.statusCode}): $body',
        );
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final data = decoded['data'];
      final models = <String>[];
      if (data is List) {
        for (final item in data) {
          if (item is Map && item['id'] is String) {
            models.add((item['id'] as String).trim());
          } else if (item is String) {
            models.add(item.trim());
          }
        }
      }
      models.removeWhere((item) => item.isEmpty);
      models.sort();
      AppLogService.instance.info(
        'Anthropic models received',
        details: 'count=${models.length} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds}',
      );
      return models;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Anthropic models request error',
        error: e,
        stackTrace: stackTrace,
        details: 'endpoint=$endpoint',
      );
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<LlmProviderResult> complete(LlmProviderRequest request) async {
    _assertValidHeaderApiKey(request.apiKey);
    final endpoint = Uri.parse(_joinUrl(request.baseUrl, '/v1/messages'));
    request.cancellationToken?.throwIfCancelled();

    for (var attempt = 0; attempt <= 3; attempt++) {
      final client = HttpClient();
      request.cancellationToken?.onCancel(() => client.close(force: true));
      try {
        final httpRequest = await client.postUrl(endpoint).timeout(
          Duration(seconds: request.timeoutSeconds),
        );

        String? systemPrompt;
        final convertedMessages = _convertOpenAiMessagesToAnthropic(
          request.messages,
          onSystemPrompt: (sys) => systemPrompt = sys,
        );

        final requestBody = <String, dynamic>{
          'model': request.model,
          'messages': convertedMessages,
          if (systemPrompt != null) 'system': systemPrompt,
          'max_tokens': 4096,
          if (request.includeTools && request.tools.isNotEmpty)
            'tools': _convertOpenAiToolsToAnthropic(request.tools),
        };

        final bodyBytes = utf8.encode(jsonEncode(requestBody));
        httpRequest.headers
          ..set('x-api-key', request.apiKey)
          ..set('anthropic-version', '2023-06-01')
          ..contentType = ContentType.json;
        httpRequest.contentLength = bodyBytes.length;
        httpRequest.add(bodyBytes);

        final response = await httpRequest.close().timeout(
          Duration(seconds: request.timeoutSeconds),
        );
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
            'Anthropic completion failed (${response.statusCode}): $body',
          );
        }

        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final contentList = decoded['content'] as List? ?? const [];
        final textBuffer = StringBuffer();
        final providerToolCalls = <LlmProviderToolCall>[];

        for (final item in contentList) {
          if (item is Map) {
            final type = item['type'];
            if (type == 'text') {
              textBuffer.write(item['text'] ?? '');
            } else if (type == 'tool_use') {
              final id = item['id'] as String? ?? '';
              final name = item['name'] as String? ?? '';
              final inputMap = item['input'] as Map? ?? const {};
              providerToolCalls.add(LlmProviderToolCall(
                id: id,
                name: name,
                argumentsJson: jsonEncode(inputMap),
              ));
            }
          }
        }

        LlmTokenUsage? usage;
        final rawUsage = decoded['usage'] as Map?;
        if (rawUsage != null) {
          final input = rawUsage['input_tokens'] as int? ?? 0;
          final output = rawUsage['output_tokens'] as int? ?? 0;
          usage = LlmTokenUsage(
            promptTokens: input,
            completionTokens: output,
            totalTokens: input + output,
            promptCacheHitTokens: rawUsage['cache_read_input_tokens'] as int?,
            promptCacheMissTokens: rawUsage['cache_creation_input_tokens'] as int?,
            reasoningTokens: null,
          );
        }

        return LlmProviderResult(
          text: textBuffer.toString(),
          toolCalls: providerToolCalls,
          usage: usage,
        );
      } catch (e, stackTrace) {
        if (request.cancellationToken?.isCancelled == true) {
          throw const LlmCancelledException();
        }
        final canRetry = _isRetryableNetworkError(e) && attempt < 3;
        if (canRetry) {
          AppLogService.instance.warning(
            'Anthropic completion network error, retrying',
            details: 'endpoint=$endpoint model=${request.model} attempt=${attempt + 1} error=$e',
          );
          await _delayBeforeNetworkRetry(attempt, request.cancellationToken);
          continue;
        }
        AppLogService.instance.error(
          'Anthropic completion request error',
          error: e,
          stackTrace: stackTrace,
          details: 'endpoint=$endpoint model=${request.model} attempt=${attempt + 1}',
        );
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('Anthropic completion failed after network retries.');
  }

  @override
  Future<LlmProviderResult> streamChat(LlmProviderRequest request) async {
    _assertValidHeaderApiKey(request.apiKey);
    final endpoint = Uri.parse(_joinUrl(request.baseUrl, '/v1/messages'));

    for (var attempt = 0; attempt <= 3; attempt++) {
      final client = HttpClient();
      request.cancellationToken?.onCancel(() => client.close(force: true));
      final startedAt = DateTime.now();
      final contentChunks = <String>[];
      final toolCalls = <int, _StreamingAnthropicToolCall>{};
      int inputTokens = 0;
      int outputTokens = 0;
      int? cacheHitTokens;
      int? cacheMissTokens;

      AppLogService.instance.info(
        'Anthropic stream request sent',
        details: 'endpoint=$endpoint model=${request.model} messages=${request.messages.length} attempt=${attempt + 1}',
      );

      try {
        request.cancellationToken?.throwIfCancelled();
        final httpRequest = await client.postUrl(endpoint);
        request.cancellationToken?.throwIfCancelled();

        String? systemPrompt;
        final convertedMessages = _convertOpenAiMessagesToAnthropic(
          request.messages,
          onSystemPrompt: (sys) => systemPrompt = sys,
        );

        final requestBody = <String, dynamic>{
          'model': request.model,
          'messages': convertedMessages,
          if (systemPrompt != null) 'system': systemPrompt,
          'max_tokens': 4096,
          if (request.includeTools && request.tools.isNotEmpty)
            'tools': _convertOpenAiToolsToAnthropic(request.tools),
          'stream': true,
        };

        final bodyBytes = utf8.encode(jsonEncode(requestBody));
        httpRequest.headers
          ..set('x-api-key', request.apiKey)
          ..set('anthropic-version', '2023-06-01')
          ..contentType = ContentType.json;
        httpRequest.contentLength = bodyBytes.length;
        httpRequest.add(bodyBytes);

        final response = await httpRequest.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.transform(utf8.decoder).join();
          AppLogService.instance.warning(
            'Anthropic stream request failed',
            details: 'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
          );
          throw StateError(
            'Anthropic stream failed (${response.statusCode}): $body',
          );
        }

        await for (final line in response
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          request.cancellationToken?.throwIfCancelled();
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final data = trimmed.substring(5).trim();
          if (data.isEmpty) continue;

          final decoded = jsonDecode(data) as Map<String, dynamic>;
          final type = decoded['type'];

          if (type == 'message_start') {
            final msg = decoded['message'] as Map?;
            final usage = msg?['usage'] as Map?;
            if (usage != null) {
              inputTokens = usage['input_tokens'] as int? ?? 0;
              outputTokens = usage['output_tokens'] as int? ?? 0;
              cacheHitTokens = usage['cache_read_input_tokens'] as int?;
              cacheMissTokens = usage['cache_creation_input_tokens'] as int?;
            }
          } else if (type == 'content_block_start') {
            final index = decoded['index'] as int? ?? 0;
            final block = decoded['content_block'] as Map?;
            if (block != null && block['type'] == 'tool_use') {
              toolCalls[index] = _StreamingAnthropicToolCall(
                id: block['id'] as String? ?? '',
                name: block['name'] as String? ?? '',
              );
            }
          } else if (type == 'content_block_delta') {
            final index = decoded['index'] as int? ?? 0;
            final delta = decoded['delta'] as Map?;
            if (delta != null) {
              final deltaType = delta['type'];
              if (deltaType == 'text_delta') {
                final text = delta['text'] as String? ?? '';
                if (text.isNotEmpty) {
                  contentChunks.add(text);
                  if (request.onTextDelta != null) {
                    request.onTextDelta!(text);
                  }
                }
              } else if (deltaType == 'input_json_delta') {
                final partial = delta['partial_json'] as String? ?? '';
                toolCalls[index]?.inputJsonBuffer.write(partial);
              }
            }
          } else if (type == 'message_delta') {
            final usage = decoded['usage'] as Map?;
            if (usage != null) {
              outputTokens = usage['output_tokens'] as int? ?? outputTokens;
              if (usage['cache_read_input_tokens'] != null) {
                cacheHitTokens = usage['cache_read_input_tokens'] as int?;
              }
              if (usage['cache_creation_input_tokens'] != null) {
                cacheMissTokens = usage['cache_creation_input_tokens'] as int?;
              }
            }
          }
        }

        final finalToolCalls = toolCalls.entries.map((entry) {
          final stc = entry.value;
          return LlmProviderToolCall(
            id: stc.id,
            name: stc.name,
            argumentsJson: stc.inputJsonBuffer.toString(),
          );
        }).toList();

        AppLogService.instance.info(
          'Anthropic stream response completed',
          details: 'elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} chunks=${contentChunks.length} toolCalls=${finalToolCalls.length} attempt=${attempt + 1}',
        );

        return LlmProviderResult(
          text: contentChunks.join(),
          toolCalls: finalToolCalls,
          usage: LlmTokenUsage(
            promptTokens: inputTokens,
            completionTokens: outputTokens,
            totalTokens: inputTokens + outputTokens,
            promptCacheHitTokens: cacheHitTokens,
            promptCacheMissTokens: cacheMissTokens,
            reasoningTokens: null,
          ),
        );
      } catch (e, stackTrace) {
        if (request.cancellationToken?.isCancelled == true ||
            e is LlmCancelledException) {
          AppLogService.instance.info(
            'Anthropic stream cancelled',
            details: 'endpoint=$endpoint model=${request.model}',
          );
          throw const LlmCancelledException();
        }
        final canRetry = _isRetryableNetworkError(e) &&
            contentChunks.isEmpty &&
            toolCalls.isEmpty &&
            attempt < 3;
        if (canRetry) {
          AppLogService.instance.warning(
            'Anthropic stream network error, retrying',
            details: 'endpoint=$endpoint model=${request.model} attempt=${attempt + 1} error=$e',
          );
          await _delayBeforeNetworkRetry(attempt, request.cancellationToken);
          continue;
        }
        AppLogService.instance.error(
          'Anthropic stream request error',
          error: e,
          stackTrace: stackTrace,
          details: 'endpoint=$endpoint model=${request.model} attempt=${attempt + 1}',
        );
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('Anthropic stream failed after network retries.');
  }

  // NOTE: This returns an OpenAI-style canonical message v1 Map.
  // It will be converted to Anthropic tool_use blocks in _convertOpenAiMessagesToAnthropic.
  // TODO: Introduce LlmCanonicalMessage to fully replace OpenAI-style Maps internally.
  @override
  Map<String, dynamic> buildAssistantToolCallMessage({
    required String? text,
    required List<LlmProviderToolCall> toolCalls,
    String? reasoningContent,
  }) {
    return {
      'role': 'assistant',
      'content': text ?? '',
      'tool_calls': [
        for (final call in toolCalls)
          {
            'id': call.id,
            'type': 'function',
            'function': {
              'name': call.name,
              'arguments': call.argumentsJson,
            },
          },
      ],
      if (reasoningContent != null && reasoningContent.trim().isNotEmpty)
        'reasoning_content': reasoningContent,
    };
  }

  // NOTE: This returns an OpenAI-style canonical message v1 Map.
  // It will be converted to Anthropic tool_result blocks in _convertOpenAiMessagesToAnthropic.
  // TODO: Introduce LlmCanonicalMessage to fully replace OpenAI-style Maps internally.
  @override
  Map<String, dynamic> buildToolResultMessage({
    required LlmProviderToolCall call,
    required String result,
  }) {
    return {
      'role': 'tool',
      'tool_call_id': call.id,
      'content': result,
    };
  }

  String _joinUrl(String baseUrl, String path) {
    return LlmUrlUtils.resolveAnthropicUrl(baseUrl, path);
  }

  List<Map<String, dynamic>> _convertOpenAiMessagesToAnthropic(
    List<Map<String, dynamic>> openAiMessages, {
    required void Function(String systemPrompt) onSystemPrompt,
  }) {
    final anthropicMessages = <Map<String, dynamic>>[];
    final systemPromptBuffer = StringBuffer();

    for (final msg in openAiMessages) {
      final role = msg['role'];
      final content = msg['content'];

      if (role == 'system') {
        if (content is String) {
          if (systemPromptBuffer.isNotEmpty) systemPromptBuffer.write('\n\n');
          systemPromptBuffer.write(content);
        }
        continue;
      }

      if (role == 'user') {
        anthropicMessages.add({
          'role': 'user',
          'content': content ?? '',
        });
        continue;
      }

      if (role == 'assistant') {
        final toolCalls = msg['tool_calls'] as List?;
        if (toolCalls == null || toolCalls.isEmpty) {
          anthropicMessages.add({
            'role': 'assistant',
            'content': content ?? '',
          });
        } else {
          final contentList = <Map<String, dynamic>>[];
          if (content is String && content.isNotEmpty) {
            contentList.add({
              'type': 'text',
              'text': content,
            });
          }
          for (final tc in toolCalls) {
            if (tc is Map) {
              final function = tc['function'] as Map?;
              final name = (function?['name'] as String?) ?? '';
              final argsString = (function?['arguments'] as String?) ?? '';
              Map<String, dynamic> parsedInput = {};
              try {
                if (argsString.isNotEmpty) {
                  parsedInput = jsonDecode(argsString) as Map<String, dynamic>;
                }
              } catch (_) {
                parsedInput = {'raw_arguments': argsString};
              }
              contentList.add({
                'type': 'tool_use',
                'id': (tc['id'] as String?) ?? '',
                'name': name,
                'input': parsedInput,
              });
            }
          }
          anthropicMessages.add({
            'role': 'assistant',
            'content': contentList,
          });
        }
        continue;
      }

      if (role == 'tool') {
        final toolCallId = msg['tool_call_id'] ?? '';
        final resultBlock = {
          'type': 'tool_result',
          'tool_use_id': toolCallId,
          'content': content ?? '',
        };

        if (anthropicMessages.isNotEmpty &&
            anthropicMessages.last['role'] == 'user' &&
            anthropicMessages.last['content'] is List) {
          final existingContent = anthropicMessages.last['content'] as List;
          existingContent.add(resultBlock);
        } else {
          anthropicMessages.add({
            'role': 'user',
            'content': [resultBlock],
          });
        }
        continue;
      }
    }

    if (systemPromptBuffer.isNotEmpty) {
      onSystemPrompt(systemPromptBuffer.toString());
    }

    final normalizedMessages = <Map<String, dynamic>>[];
    for (final msg in anthropicMessages) {
      if (normalizedMessages.isEmpty) {
        normalizedMessages.add(msg);
        continue;
      }

      final prevMsg = normalizedMessages.last;
      if (prevMsg['role'] == msg['role']) {
        final prevContent = prevMsg['content'];
        final nextContent = msg['content'];
        if (prevContent is String && nextContent is String) {
          prevMsg['content'] = '$prevContent\n\n$nextContent';
        } else {
          final prevList = prevContent is List
              ? prevContent
              : [{'type': 'text', 'text': prevContent}];
          final nextList = nextContent is List
              ? nextContent
              : [{'type': 'text', 'text': nextContent}];
          prevMsg['content'] = [...prevList, ...nextList];
        }
      } else {
        normalizedMessages.add(msg);
      }
    }

    return normalizedMessages;
  }

  List<Map<String, dynamic>> _convertOpenAiToolsToAnthropic(
      List<Map<String, dynamic>> openAiTools) {
    final anthropicTools = <Map<String, dynamic>>[];
    for (final tool in openAiTools) {
      if (tool['type'] == 'function') {
        final function = tool['function'] as Map<String, dynamic>?;
        if (function != null) {
          anthropicTools.add({
            'name': function['name'],
            'description': function['description'] ?? '',
            'input_schema': function['parameters'] ?? {
              'type': 'object',
              'properties': {},
            },
          });
        }
      }
    }
    return anthropicTools;
  }

  bool _isRetryableNetworkError(Object error) {
    return error is SocketException ||
        error is HttpException ||
        error is HandshakeException ||
        error is TlsException ||
        error is IOException;
  }

  Future<void> _delayBeforeNetworkRetry(
    int attempt,
    LlmCancellationToken? cancellationToken,
  ) async {
    cancellationToken?.throwIfCancelled();
    await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
    cancellationToken?.throwIfCancelled();
  }

  void _assertValidHeaderApiKey(String apiKey) {
    if (apiKey.contains(RegExp(r'[\r\n\t]')) ||
        apiKey.contains('package:flutter/') ||
        apiKey.contains('Failed assertion') ||
        apiKey.contains('docs.flutter.dev/testing/errors')) {
      throw const FormatException(
        'Invalid API key. Please re-enter the provider API key in LLM settings.',
      );
    }
  }
}




