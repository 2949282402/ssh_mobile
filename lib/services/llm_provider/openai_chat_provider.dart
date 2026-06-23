import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_log_service.dart';
import '../llm_runtime/llm_runtime_types.dart';
import '../storage_service.dart';
import 'llm_provider_adapter.dart';
import 'llm_provider_types.dart';
import 'llm_url_utils.dart';

class OpenAiChatProvider implements LlmProviderAdapter {
  const OpenAiChatProvider();

  @override
  Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('API key is not configured.');
    }
    _assertValidHeaderApiKey(apiKey);

    final endpoint = Uri.parse(resolveOpenAiCompatibleUrl(baseUrl, '/models'));
    final client = HttpClient();
    final startedAt = DateTime.now();
    AppLogService.instance.info(
      'LLM models request sent',
      details: 'endpoint=$endpoint',
    );
    try {
      final request = await client.getUrl(endpoint).timeout(
            const Duration(seconds: 30),
          );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $apiKey',
      );
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        AppLogService.instance.warning(
          'LLM models request failed',
          details: 'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
        );
        throw StateError(
          'Fetch models failed (${response.statusCode}): $body',
        );
      }

      final data = jsonDecode(body);
      if (data is Map && data['data'] is List) {
        final list = data['data'] as List;
        final ids = list
            .map((item) => item is Map ? item['id'] as String? : null)
            .whereType<String>()
            .toList();
        AppLogService.instance.info(
          'LLM models request completed',
          details: 'count=${ids.length} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds}',
        );
        return ids;
      }
      throw StateError('Unexpected models response format.');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<LlmProviderResult> complete(LlmProviderRequest request) async {
    _assertValidHeaderApiKey(request.apiKey);
    final endpoint = Uri.parse(resolveOpenAiCompatibleUrl(request.baseUrl, '/chat/completions'));

    for (var attempt = 0; attempt <= 3; attempt++) {
      final client = HttpClient();
      request.cancellationToken?.onCancel(() => client.close(force: true));
      final startedAt = DateTime.now();

      AppLogService.instance.info(
        'LLM completion request sent',
        details: 'endpoint=$endpoint model=${request.model} messages=${request.messages.length} attempt=${attempt + 1}',
      );

      try {
        request.cancellationToken?.throwIfCancelled();
        final httpRequest = await client.postUrl(endpoint);
        request.cancellationToken?.throwIfCancelled();

        final useTools = request.includeTools && request.tools.isNotEmpty;
        final requestBody = <String, dynamic>{
          'model': request.model,
          'messages': request.messages,
          if (useTools) ...{
            'tools': request.tools,
            'tool_choice': 'auto',
          },
          if (request.includeReasoningParams)
            ..._providerReasoningParams(
              baseUrl: request.baseUrl,
              model: request.model,
              deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
              deepSeekReasoningEffort: request.deepSeekReasoningEffort,
              openAiReasoningEffort: request.openAiReasoningEffort,
            ),
        };

        final bodyBytes = utf8.encode(jsonEncode(requestBody));
        httpRequest.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer ${request.apiKey}')
          ..contentType = ContentType.json;
        httpRequest.contentLength = bodyBytes.length;
        httpRequest.add(bodyBytes);

        final response = await httpRequest.close().timeout(
          Duration(seconds: request.timeoutSeconds),
        );
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (request.includeReasoningParams && response.statusCode == 400 && _looksLikeReasoningParamUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM completion reasoning params unsupported, retrying without them',
              details: 'endpoint=$endpoint model=${request.model} bodyChars=${body.length}',
            );
            return complete(LlmProviderRequest(
              baseUrl: request.baseUrl,
              apiKey: request.apiKey,
              model: request.model,
              messages: request.messages,
              tools: request.tools,
              openAiReasoningEffort: request.openAiReasoningEffort,
              deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
              deepSeekReasoningEffort: request.deepSeekReasoningEffort,
              includeTools: request.includeTools,
              includeUsage: request.includeUsage,
              includeReasoningParams: false,
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }
          if (useTools && looksLikeToolUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM completion tools unsupported, retrying without them',
              details: 'endpoint=$endpoint model=${request.model} bodyChars=${body.length}',
            );
            return complete(LlmProviderRequest(
              baseUrl: request.baseUrl,
              apiKey: request.apiKey,
              model: request.model,
              messages: request.messages,
              tools: const [],
              openAiReasoningEffort: request.openAiReasoningEffort,
              deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
              deepSeekReasoningEffort: request.deepSeekReasoningEffort,
              includeTools: false,
              includeUsage: request.includeUsage,
              includeReasoningParams: request.includeReasoningParams,
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }

          AppLogService.instance.warning(
            'LLM completion failed',
            details: 'status=${response.statusCode} bodyChars=${body.length}',
          );
          throw StateError(
            'LLM completion failed (${response.statusCode}): $body',
          );
        }

        final data = jsonDecode(body);
        if (data is! Map) {
          throw StateError('Unexpected completion response body shape.');
        }
        final choices = data['choices'] as List?;
        if (choices == null || choices.isEmpty) {
          throw StateError('No choices in completion response.');
        }
        final firstChoice = choices.first as Map;
        final message = firstChoice['message'] as Map;
        final contentText = message['content'] as String? ?? '';

        String? reasoningContent;
        if (message.containsKey('reasoning_content')) {
          reasoningContent = message['reasoning_content'] as String?;
        } else if (message.containsKey('reasoning')) {
          reasoningContent = message['reasoning'] as String?;
        }

        final rawToolCalls = message['tool_calls'] as List?;
        final toolCalls = <LlmProviderToolCall>[];
        if (rawToolCalls != null) {
          for (final rawCall in rawToolCalls) {
            if (rawCall is Map) {
              final id = rawCall['id'] as String? ?? '';
              final function = rawCall['function'] as Map?;
              final name = (function?['name'] as String?) ?? '';
              final args = (function?['arguments'] as String?) ?? '';
              toolCalls.add(LlmProviderToolCall(
                id: id,
                name: name,
                argumentsJson: args,
              ));
            }
          }
        }

        final usageJson = data['usage'];
        final usage = usageJson is Map ? LlmTokenUsage.fromJson(Map<String, dynamic>.from(usageJson)) : null;

        AppLogService.instance.info(
          'LLM completion completed',
          details: 'elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} chars=${contentText.length} toolCalls=${toolCalls.length} attempt=${attempt + 1}',
        );

        return LlmProviderResult(
          text: contentText,
          reasoningContent: reasoningContent,
          toolCalls: toolCalls,
          usage: usage,
        );
      } catch (e, stackTrace) {
        if (request.cancellationToken?.isCancelled == true ||
            e is LlmCancelledException) {
          AppLogService.instance.info(
            'LLM completion cancelled',
            details: 'endpoint=$endpoint model=${request.model}',
          );
          throw const LlmCancelledException();
        }
        final canRetry = _isRetryableNetworkError(e) && attempt < 3;
        if (canRetry) {
          AppLogService.instance.warning(
            'LLM completion retryable network error',
            details: 'error=$e attempt=${attempt + 1}',

          );
          await _delayBeforeNetworkRetry(attempt, request.cancellationToken);
          continue;
        }
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('LLM completion failed after network retries.');
  }

  @override
  Future<LlmProviderResult> streamChat(LlmProviderRequest request) async {
    _assertValidHeaderApiKey(request.apiKey);
    final endpoint = Uri.parse(resolveOpenAiCompatibleUrl(request.baseUrl, '/chat/completions'));

    for (var attempt = 0; attempt <= 3; attempt++) {
      final client = HttpClient();
      request.cancellationToken?.onCancel(() => client.close(force: true));
      final startedAt = DateTime.now();
      final contentChunks = <String>[];
      final reasoningContent = StringBuffer();
      final toolCalls = <int, _StreamingToolCall>{};
      LlmTokenUsage? usage;

      AppLogService.instance.info(
        'LLM stream request sent',
        details: 'endpoint=$endpoint model=${request.model} messages=${request.messages.length} attempt=${attempt + 1}',
      );

      try {
        request.cancellationToken?.throwIfCancelled();
        final httpRequest = await client.postUrl(endpoint);
        request.cancellationToken?.throwIfCancelled();

        final useTools = request.includeTools && request.tools.isNotEmpty;
        final requestBody = <String, dynamic>{
          'model': request.model,
          'messages': request.messages,
          'stream': true,
          if (useTools) ...{
            'tools': request.tools,
            'tool_choice': 'auto',
          },
          if (request.includeReasoningParams)
            ..._providerReasoningParams(
              baseUrl: request.baseUrl,
              model: request.model,
              deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
              deepSeekReasoningEffort: request.deepSeekReasoningEffort,
              openAiReasoningEffort: request.openAiReasoningEffort,
            ),
        };

        if (request.includeUsage) {
          requestBody['stream_options'] = {'include_usage': true};
        }

        final bodyBytes = utf8.encode(jsonEncode(requestBody));
        httpRequest.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer ${request.apiKey}')
          ..contentType = ContentType.json;
        httpRequest.contentLength = bodyBytes.length;
        httpRequest.add(bodyBytes);

        final response = await httpRequest.close().timeout(
          Duration(seconds: request.timeoutSeconds),
        );

        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.transform(utf8.decoder).join();

          if (request.includeUsage &&
              response.statusCode == 400 &&
              (body.toLowerCase().contains('stream_options') ||
                  body.toLowerCase().contains('streamoptions'))) {
            AppLogService.instance.warning(
              'LLM stream options usage unsupported, retrying without them',
              details: 'endpoint=$endpoint model=${request.model} bodyChars=${body.length}',
            );
            return streamChat(LlmProviderRequest(
              baseUrl: request.baseUrl,
              apiKey: request.apiKey,
              model: request.model,
              messages: request.messages,
              tools: request.tools,
              openAiReasoningEffort: request.openAiReasoningEffort,
              deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
              deepSeekReasoningEffort: request.deepSeekReasoningEffort,
              includeTools: request.includeTools,
              includeUsage: false,
              includeReasoningParams: request.includeReasoningParams,
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }

          if (useTools && response.statusCode == 400 && looksLikeToolUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM stream tools unsupported, retrying without them',
              details: 'endpoint=$endpoint model=${request.model} bodyChars=${body.length}',
            );
            return streamChat(LlmProviderRequest(
              baseUrl: request.baseUrl,
              apiKey: request.apiKey,
              model: request.model,
              messages: request.messages,
              tools: const [],
              openAiReasoningEffort: request.openAiReasoningEffort,
              deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
              deepSeekReasoningEffort: request.deepSeekReasoningEffort,
              includeTools: false,
              includeUsage: request.includeUsage,
              includeReasoningParams: request.includeReasoningParams,
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }

          if (request.includeReasoningParams && response.statusCode == 400 && _looksLikeReasoningParamUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM reasoning params unsupported, retrying without them',
              details: 'endpoint=$endpoint model=${request.model} bodyChars=${body.length}',
            );
            return streamChat(LlmProviderRequest(
              baseUrl: request.baseUrl,
              apiKey: request.apiKey,
              model: request.model,
              messages: request.messages,
              tools: request.tools,
              openAiReasoningEffort: request.openAiReasoningEffort,
              deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
              deepSeekReasoningEffort: request.deepSeekReasoningEffort,
              includeTools: request.includeTools,
              includeUsage: request.includeUsage,
              includeReasoningParams: false,
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }

          AppLogService.instance.warning(
            'LLM stream failed',
            details: 'status=${response.statusCode} bodyChars=${body.length}',
          );
          throw StateError(
            'LLM stream failed (${response.statusCode}): $body',
          );
        }

        final lines = response
            .transform(utf8.decoder)
            .transform(const LineSplitter());

        await for (final line in lines) {
          request.cancellationToken?.throwIfCancelled();
          if (line.trim().isEmpty) continue;
          if (!line.startsWith('data:')) continue;

          final dataStr = line.substring(5).trim();
          if (dataStr == '[DONE]') continue;

          Map<dynamic, dynamic> parsed;
          try {
            parsed = jsonDecode(dataStr) as Map;
          } catch (_) {
            continue;
          }

          final usageJson = parsed['usage'];
          if (usageJson is Map) {
            usage = LlmTokenUsage.fromJson(Map<String, dynamic>.from(usageJson));
          }

          final choices = parsed['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;

          final firstChoice = choices.first as Map;
          final delta = firstChoice['delta'] as Map?;
          if (delta == null) continue;

          final text = delta['content'];
          if (text is String && text.isNotEmpty) {
            contentChunks.add(text);
            if (request.onTextDelta != null) {
              request.onTextDelta!(text);
            }
          }

          final reasoning = delta['reasoning_content'];
          if (reasoning is String && reasoning.isNotEmpty) {
            reasoningContent.write(reasoning);
          }

          final rawToolCalls = delta['tool_calls'];
          if (rawToolCalls is List) {
            for (final rawCall in rawToolCalls) {
              if (rawCall is! Map) continue;
              final index = rawCall['index'] as int? ?? 0;
              final current = toolCalls.putIfAbsent(
                index,
                () => _StreamingToolCall(id: '', name: '', arguments: ''),
              );
              final id = rawCall['id'];
              if (id is String && id.isNotEmpty) current.id = id;
              final function = rawCall['function'];
              if (function is Map) {
                final name = function['name'];
                if (name is String && name.isNotEmpty) current.name += name;
                final arguments = function['arguments'];
                if (arguments is String && arguments.isNotEmpty) {
                  current.arguments += arguments;
                }
              }
            }
          }
        }

        final calls = toolCalls.entries
            .where((entry) => entry.value.name.trim().isNotEmpty)
            .map((entry) {
          final call = entry.value;
          if (call.id.trim().isEmpty) {
            call.id = 'call_${entry.key}';
          }
          return call;
        }).toList();

        AppLogService.instance.info(
          'LLM stream response completed',
          details: 'elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} chunks=${contentChunks.length} toolCalls=${calls.length} attempt=${attempt + 1}',
        );

        return LlmProviderResult(
          text: contentChunks.join(),
          reasoningContent: reasoningContent.toString(),
          toolCalls: calls.map((c) => LlmProviderToolCall(
            id: c.id,
            name: c.name,
            argumentsJson: c.arguments,
          )).toList(),
          usage: usage,
        );
      } catch (e, stackTrace) {
        if (request.cancellationToken?.isCancelled == true ||
            e is LlmCancelledException) {
          AppLogService.instance.info(
            'LLM stream cancelled',
            details: 'endpoint=$endpoint model=${request.model}',
          );
          throw const LlmCancelledException();
        }
        final canRetry = _isRetryableNetworkError(e) &&
            contentChunks.isEmpty &&
            reasoningContent.isEmpty &&
            toolCalls.isEmpty &&
            attempt < 3;
        if (canRetry) {
          AppLogService.instance.warning(
            'LLM stream retryable network error',
            details: 'error=$e attempt=${attempt + 1}',

          );
          await _delayBeforeNetworkRetry(attempt, request.cancellationToken);
          continue;
        }
        rethrow;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('LLM stream failed after network retries.');
  }

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

  static String resolveOpenAiCompatibleUrl(String baseUrl, String path) {
    return LlmUrlUtils.resolveOpenAiCompatibleUrl(baseUrl, path);
  }

  static bool looksLikeToolUnsupportedError(String body) {
    return LlmUrlUtils.looksLikeToolUnsupportedError(body);
  }

  Map<String, dynamic> _providerReasoningParams({
    required String baseUrl,
    required String model,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
  }) {
    if (isDeepSeekModelId(model) || _isDeepSeekBaseUrl(baseUrl)) {
      final params = <String, dynamic>{
        'thinking': {
          'type': deepSeekThinkingEnabled ? 'enabled' : 'disabled',
        },
      };
      if (deepSeekThinkingEnabled) {
        params['reasoning_effort'] = DeepSeekReasoningEffort.normalize(
          deepSeekReasoningEffort,
        );
      }
      return params;
    }
    if (supportsOpenAiReasoningEffort(model)) {
      return {
        'reasoning_effort': OpenAiReasoningEffort.normalize(
          openAiReasoningEffort,
        ),
      };
    }
    return const {};
  }

  bool _looksLikeReasoningParamUnsupportedError(String text) {
    final lower = text.toLowerCase();
    return lower.contains('reasoning_effort') ||
        lower.contains('xhigh') ||
        lower.contains('"thinking"') ||
        lower.contains("'thinking'") ||
        lower.contains('unknown parameter') ||
        lower.contains('unsupported parameter') ||
        lower.contains('does not support reasoning');
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

  bool isDeepSeekModelId(String model) {
    final lower = model.toLowerCase();
    return lower.contains('deepseek');
  }

  bool _isDeepSeekBaseUrl(String baseUrl) {
    return baseUrl.toLowerCase().contains('deepseek');
  }

  bool supportsOpenAiReasoningEffort(String model) {
    final lower = model.toLowerCase();
    return lower.startsWith('o1') || lower.startsWith('o3');
  }

  void _assertValidHeaderApiKey(String apiKey) {
    if (apiKey.contains('\r') || apiKey.contains('\n')) {
      throw ArgumentError('API key contains invalid newline characters.');
    }
  }
}

class _StreamingToolCall {
  String id;
  String name;
  String arguments;

  _StreamingToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

