import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_log_service.dart';
import '../llm_chat_service.dart';
import '../storage_service.dart';
import 'llm_provider_adapter.dart';
import 'llm_provider_types.dart';

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
        'LLM models received',
        details: 'count=${models.length} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds}',
      );
      return models;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM models request error',
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
    final endpoint = Uri.parse(resolveOpenAiCompatibleUrl(request.baseUrl, '/chat/completions'));
    request.cancellationToken?.throwIfCancelled();

    for (var attempt = 0; attempt <= 3; attempt++) {
      final client = HttpClient();
      request.cancellationToken?.onCancel(() => client.close(force: true));
      try {
        final httpRequest = await client.postUrl(endpoint).timeout(
          Duration(seconds: request.timeoutSeconds),
        );
        final requestBody = <String, dynamic>{
          'model': request.model,
          'messages': request.messages,
        };
        requestBody.addAll(
          _providerReasoningParams(
            baseUrl: request.baseUrl,
            model: request.model,
            deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
            deepSeekReasoningEffort: request.deepSeekReasoningEffort,
            openAiReasoningEffort: request.openAiReasoningEffort,
          ),
        );

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
          if (response.statusCode == 400 && _looksLikeReasoningParamUnsupportedError(body)) {
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
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }
          throw StateError(
            'LLM completion failed (${response.statusCode}): $body',
          );
        }

        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final text = _contentFromChatResponse(decoded);
        final choices = decoded['choices'] as List?;
        String? reasoningContent;
        final providerToolCalls = <LlmProviderToolCall>[];
        LlmTokenUsage? usage;

        if (choices != null && choices.isNotEmpty) {
          final firstChoice = choices.first as Map;
          final message = firstChoice['message'] as Map?;
          if (message != null) {
            reasoningContent = message['reasoning_content'] as String?;
            final toolCalls = message['tool_calls'] as List?;
            if (toolCalls != null) {
              for (final tc in toolCalls) {
                if (tc is Map) {
                  final function = tc['function'] as Map?;
                  providerToolCalls.add(LlmProviderToolCall(
                    id: (tc['id'] as String?) ?? '',
                    name: (function?['name'] as String?) ?? '',
                    argumentsJson: (function?['arguments'] as String?) ?? '',
                  ));
                }
              }
            }
          }
        }

        final rawUsage = decoded['usage'];
        if (rawUsage is Map<String, dynamic>) {
          usage = LlmTokenUsage.fromJson(rawUsage);
        }

        return LlmProviderResult(
          text: text,
          reasoningContent: reasoningContent,
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
            'LLM completion network error, retrying',
            details: 'endpoint=$endpoint model=${request.model} attempt=${attempt + 1} error=$e',
          );
          await _delayBeforeNetworkRetry(attempt, request.cancellationToken);
          continue;
        }
        AppLogService.instance.error(
          'LLM completion request error',
          error: e,
          stackTrace: stackTrace,
          details: 'endpoint=$endpoint model=${request.model} attempt=${attempt + 1}',
        );
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
      final toolCalls = <int, StreamingToolCall>{};
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
          if (request.includeUsage) 'stream_options': {'include_usage': true},
        };

        requestBody.addAll(
          _providerReasoningParams(
            baseUrl: request.baseUrl,
            model: request.model,
            deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
            deepSeekReasoningEffort: request.deepSeekReasoningEffort,
            openAiReasoningEffort: request.openAiReasoningEffort,
          ),
        );

        final bodyBytes = utf8.encode(jsonEncode(requestBody));
        httpRequest.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer ${request.apiKey}')
          ..contentType = ContentType.json;
        httpRequest.contentLength = bodyBytes.length;
        httpRequest.add(bodyBytes);

        final response = await httpRequest.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.transform(utf8.decoder).join();
          if (request.includeUsage &&
              response.statusCode == 400 &&
              (body.contains('stream_options') || body.contains('include_usage'))) {
            AppLogService.instance.warning(
              'LLM stream usage unsupported, retrying without usage',
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
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }
          if (request.includeTools && looksLikeToolUnsupportedError(body)) {
            AppLogService.instance.warning(
              'LLM stream tools unsupported, retrying without tools',
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
              includeTools: false,
              includeUsage: request.includeUsage,
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }
          if (response.statusCode == 400 && _looksLikeReasoningParamUnsupportedError(body)) {
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
              cancellationToken: request.cancellationToken,
              onTextDelta: request.onTextDelta,
              timeoutSeconds: request.timeoutSeconds,
            ));
          }
          AppLogService.instance.warning(
            'LLM stream request failed',
            details: 'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
          );
          throw StateError(
            'LLM stream failed (${response.statusCode}): $body',
          );
        }

        await for (final line in response
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          request.cancellationToken?.throwIfCancelled();
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') break;
          if (data.isEmpty) continue;

          final decoded = jsonDecode(data) as Map<String, dynamic>;
          final rawUsage = decoded['usage'];
          if (rawUsage is Map<String, dynamic>) {
            usage = LlmTokenUsage.fromJson(rawUsage);
          }
          final choices = decoded['choices'] as List<dynamic>? ?? const [];
          if (choices.isEmpty) continue;
          final delta =
              (choices.first as Map<String, dynamic>)['delta'] as Map?;
          if (delta == null) continue;

          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            contentChunks.add(content);
            if (request.onTextDelta != null) {
              request.onTextDelta!(content);
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
                () => StreamingToolCall(id: '', name: '', arguments: ''),
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
            'LLM stream network error, retrying',
            details: 'endpoint=$endpoint model=${request.model} attempt=${attempt + 1} error=$e',
          );
          await _delayBeforeNetworkRetry(attempt, request.cancellationToken);
          continue;
        }
        AppLogService.instance.error(
          'LLM stream request error',
          error: e,
          stackTrace: stackTrace,
          details: 'endpoint=$endpoint model=${request.model} attempt=${attempt + 1}',
        );
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
    final trimmedBase = baseUrl
        .trim()
        .split(RegExp(r'[?#]'))
        .first
        .replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.tryParse(trimmedBase);
    if (uri == null) return '$trimmedBase$normalizedPath';

    final basePath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (basePath.endsWith(normalizedPath)) return trimmedBase;
    const chatPath = '/chat/completions';
    const modelsPath = '/models';
    if (normalizedPath == modelsPath && basePath.endsWith(chatPath)) {
      final nextPath =
          '${basePath.substring(0, basePath.length - chatPath.length)}$modelsPath';
      return uri
          .replace(path: nextPath, query: null, fragment: null)
          .toString();
    }
    if (normalizedPath == chatPath && basePath.endsWith(modelsPath)) {
      final nextPath =
          '${basePath.substring(0, basePath.length - modelsPath.length)}$chatPath';
      return uri
          .replace(path: nextPath, query: null, fragment: null)
          .toString();
    }
    return '$trimmedBase$normalizedPath';
  }

  static bool looksLikeToolUnsupportedError(String body) {
    final lower = body.toLowerCase();
    return lower.contains('tool_choice') ||
        lower.contains('"tools"') ||
        lower.contains("'tools'") ||
        lower.contains('tools is not supported') ||
        lower.contains('tool calls') ||
        lower.contains('function calling');
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

  bool _isDeepSeekBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri?.host.toLowerCase().endsWith('deepseek.com') == true;
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
