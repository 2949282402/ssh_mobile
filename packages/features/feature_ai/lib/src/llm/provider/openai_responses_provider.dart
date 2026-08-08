import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/llm/runtime/llm_runtime_types.dart';
import 'llm_provider_adapter.dart';
import 'llm_provider_types.dart';
import 'llm_url_utils.dart';

class OpenAiResponsesProvider implements LlmProviderAdapter {
  const OpenAiResponsesProvider();

  @override
  Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('API key is not configured.');
    }
    _assertValidHeaderApiKey(apiKey);

    final endpoint = Uri.parse(
      LlmUrlUtils.resolveOpenAiCompatibleUrl(baseUrl, '/models'),
    );
    final client = http.Client();
    final startedAt = DateTime.now();

    AppLogService.instance.info(
      'LLM Models request sent (Responses API)',
      details: 'endpoint=$endpoint',
    );

    try {
      final response = await client
          .get(endpoint, headers: {'Authorization': 'Bearer $apiKey'})
          .timeout(const Duration(seconds: 30));

      final body = response.body;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        AppLogService.instance.warning(
          'LLM Models request failed (Responses API)',
          details:
              'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
        );
        throw StateError('Fetch models failed (${response.statusCode}): $body');
      }

      final data = jsonDecode(body);
      if (data is Map && data['data'] is List) {
        final list = data['data'] as List;
        final ids = list
            .map((item) {
              if (item is Map) {
                final id = item['id'];
                return id is String ? id.trim() : null;
              } else if (item is String) {
                return item.trim();
              }
              return null;
            })
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toList();

        ids.sort();
        AppLogService.instance.info(
          'LLM Models request completed (Responses API)',
          details:
              'count=${ids.length} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds}',
        );
        return ids;
      }
      throw StateError('Unexpected models response format.');
    } finally {
      client.close();
    }
  }

  @override
  Future<LlmProviderResult> complete(LlmProviderRequest request) async {
    _assertValidHeaderApiKey(request.apiKey);

    final endpoint = Uri.parse(
      LlmUrlUtils.resolveOpenAiCompatibleUrl(request.baseUrl, '/responses'),
    );

    for (var attempt = 0; attempt <= 3; attempt++) {
      final client = http.Client();
      request.cancellationToken?.onCancel(() => client.close());
      final startedAt = DateTime.now();

      AppLogService.instance.info(
        'LLM responses completion request sent',
        details:
            'endpoint=$endpoint model=${request.model} messages=${request.messages.length} attempt=${attempt + 1}',
      );

      try {
        request.cancellationToken?.throwIfCancelled();

        final useTools = request.includeTools && request.tools.isNotEmpty;
        final inputMessages = <Map<String, dynamic>>[];
        String? systemInstructions;
        final sysPromptBuffer = StringBuffer();

        for (final msg in request.messages) {
          final role = msg['role'];
          final content = msg['content'];

          if (role == 'system' || role == 'developer') {
            if (content is String) {
              if (sysPromptBuffer.isNotEmpty) sysPromptBuffer.write('\n\n');
              sysPromptBuffer.write(content);
            }
          } else {
            final converted = <String, dynamic>{'role': role};
            if (content != null) {
              converted['content'] = content;
            }
            if (msg['tool_calls'] != null) {
              converted['tool_calls'] = msg['tool_calls'];
            }
            if (msg['tool_call_id'] != null) {
              converted['tool_call_id'] = msg['tool_call_id'];
            }
            inputMessages.add(converted);
          }
        }
        if (sysPromptBuffer.isNotEmpty) {
          systemInstructions = sysPromptBuffer.toString();
        }

        final requestBody = <String, dynamic>{
          'model': request.model,
          // ignore: use_null_aware_elements
          if (systemInstructions != null) 'instructions': systemInstructions,
          'input': inputMessages,
          if (useTools) 'tools': request.tools,
          if (request.includeReasoningParams)
            ..._providerReasoningParams(
              baseUrl: request.baseUrl,
              model: request.model,
              deepSeekThinkingEnabled: request.deepSeekThinkingEnabled,
              deepSeekReasoningEffort: request.deepSeekReasoningEffort,
              openAiReasoningEffort: request.openAiReasoningEffort,
            ),
        };

        request.cancellationToken?.throwIfCancelled();

        final response = await client
            .post(
              endpoint,
              headers: {
                'Authorization': 'Bearer ${request.apiKey}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(requestBody),
            )
            .timeout(Duration(seconds: request.timeoutSeconds));

        final body = response.body;

        if (response.statusCode < 200 || response.statusCode >= 300) {
          AppLogService.instance.warning(
            'LLM responses completion failed',
            details: 'status=${response.statusCode} bodyChars=${body.length}',
          );
          throw StateError(
            'LLM responses completion failed (${response.statusCode}): $body',
          );
        }

        final data = jsonDecode(body);
        if (data is! Map) {
          throw StateError('Unexpected completion response body shape.');
        }

        final output = data['output'] as List?;
        if (output == null || output.isEmpty) {
          throw StateError('No output in response.');
        }

        final contentParts = <String>[];
        final toolCalls = <LlmProviderToolCall>[];

        for (final item in output) {
          if (item is Map) {
            final type = item['type'];
            if (type == 'message') {
              final content = item['content'] as List?;
              if (content != null) {
                for (final part in content) {
                  if (part is Map && part['type'] == 'text') {
                    contentParts.add(part['text'] as String? ?? '');
                  }
                }
              }
            } else if (type == 'function_call') {
              final id = item['id'] as String? ?? '';
              final name = item['name'] as String? ?? '';
              final arguments = item['arguments'] as String? ?? '';
              toolCalls.add(
                LlmProviderToolCall(
                  id: id,
                  name: name,
                  argumentsJson: arguments,
                ),
              );
            }
          }
        }

        final usageJson = data['usage'];
        final usage = usageJson is Map
            ? LlmTokenUsage.fromJson(Map<String, dynamic>.from(usageJson))
            : null;

        AppLogService.instance.info(
          'LLM responses completion completed',
          details:
              'elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} chars=${contentParts.join().length} toolCalls=${toolCalls.length} attempt=${attempt + 1}',
        );

        return LlmProviderResult(
          text: contentParts.join(),
          toolCalls: toolCalls,
          usage: usage,
        );
      } catch (e) {
        if (request.cancellationToken?.isCancelled == true ||
            e is LlmCancelledException) {
          AppLogService.instance.info(
            'LLM responses completion cancelled',
            details: 'endpoint=$endpoint model=${request.model}',
          );
          throw const LlmCancelledException();
        }

        final canRetry = _isRetryableNetworkError(e) && attempt < 3;
        if (canRetry) {
          AppLogService.instance.warning(
            'LLM responses completion retryable network error',
            details: 'error=$e attempt=${attempt + 1}',
          );
          await _delayBeforeNetworkRetry(attempt, request.cancellationToken);
          continue;
        }
        rethrow;
      } finally {
        client.close();
      }
    }
    throw StateError('LLM responses completion failed after network retries.');
  }

  @override
  Future<LlmProviderResult> streamChat(LlmProviderRequest request) async {
    _assertValidHeaderApiKey(request.apiKey);

    final endpoint = Uri.parse(
      LlmUrlUtils.resolveOpenAiCompatibleUrl(request.baseUrl, '/responses'),
    );

    for (var attempt = 0; attempt <= 3; attempt++) {
      final client = http.Client();
      request.cancellationToken?.onCancel(() => client.close());
      final startedAt = DateTime.now();

      final contentChunks = <String>[];
      final toolCalls = <String, _StreamingToolCall>{};
      LlmTokenUsage? usage;

      AppLogService.instance.info(
        'LLM responses stream request sent',
        details:
            'endpoint=$endpoint model=${request.model} messages=${request.messages.length} attempt=${attempt + 1}',
      );

      try {
        request.cancellationToken?.throwIfCancelled();

        final useTools = request.includeTools && request.tools.isNotEmpty;
        final inputMessages = <Map<String, dynamic>>[];
        String? systemInstructions;
        final sysPromptBuffer = StringBuffer();

        for (final msg in request.messages) {
          final role = msg['role'];
          final content = msg['content'];

          if (role == 'system' || role == 'developer') {
            if (content is String) {
              if (sysPromptBuffer.isNotEmpty) sysPromptBuffer.write('\n\n');
              sysPromptBuffer.write(content);
            }
          } else {
            final converted = <String, dynamic>{'role': role};
            if (content != null) {
              converted['content'] = content;
            }
            if (msg['tool_calls'] != null) {
              converted['tool_calls'] = msg['tool_calls'];
            }
            if (msg['tool_call_id'] != null) {
              converted['tool_call_id'] = msg['tool_call_id'];
            }
            inputMessages.add(converted);
          }
        }
        if (sysPromptBuffer.isNotEmpty) {
          systemInstructions = sysPromptBuffer.toString();
        }

        final requestBody = <String, dynamic>{
          'model': request.model,
          // ignore: use_null_aware_elements
          if (systemInstructions != null) 'instructions': systemInstructions,
          'input': inputMessages,
          'stream': true,
          if (useTools) 'tools': request.tools,
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
        request.cancellationToken?.throwIfCancelled();

        final httpRequest = http.Request('POST', endpoint);
        httpRequest.headers.addAll({
          'Authorization': 'Bearer ${request.apiKey}',
          'Content-Type': 'application/json',
        });
        httpRequest.bodyBytes = bodyBytes;

        final response = await client
            .send(httpRequest)
            .timeout(Duration(seconds: request.timeoutSeconds));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.stream.bytesToString();
          AppLogService.instance.warning(
            'LLM responses stream failed',
            details: 'status=${response.statusCode} bodyChars=${body.length}',
          );
          throw StateError(
            'LLM responses stream failed (${response.statusCode}): $body',
          );
        }

        final lines = response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());

        await for (final line in lines) {
          request.cancellationToken?.throwIfCancelled();
          if (line.trim().isEmpty) continue;
          if (!line.startsWith('data:')) continue;

          final dataStr = line.substring(5).trim();
          if (dataStr == '[DONE]') break;

          Map<dynamic, dynamic> parsed;
          try {
            parsed = jsonDecode(dataStr) as Map;
          } catch (_) {
            continue;
          }

          final eventType = parsed['type'];
          if (eventType == 'response.output_text.delta') {
            final text = parsed['delta'];
            if (text is String && text.isNotEmpty) {
              contentChunks.add(text);
              if (request.onTextDelta != null) {
                request.onTextDelta!(text);
              }
            }
          } else if (eventType == 'response.output_item.added') {
            final item = parsed['item'];
            if (item is Map && item['type'] == 'function_call') {
              final id = item['id'] as String? ?? '';
              final name = item['name'] as String? ?? '';
              toolCalls[id] = _StreamingToolCall(
                id: id,
                name: name,
                arguments: '',
              );
            }
          } else if (eventType == 'response.function_call_arguments.delta') {
            final itemId = parsed['item_id'] as String? ?? '';
            final delta = parsed['delta'] as String? ?? '';
            if (itemId.isNotEmpty) {
              final current = toolCalls[itemId];
              if (current != null) {
                current.arguments += delta;
              }
            }
          }

          final resp = parsed['response'];
          if (resp is Map) {
            final usageJson = resp['usage'];
            if (usageJson is Map) {
              usage = LlmTokenUsage.fromJson(
                Map<String, dynamic>.from(usageJson),
              );
            }
          }
        }

        final calls = toolCalls.values
            .where((c) => c.name.trim().isNotEmpty)
            .map(
              (c) => LlmProviderToolCall(
                id: c.id,
                name: c.name,
                argumentsJson: c.arguments,
              ),
            )
            .toList();

        AppLogService.instance.info(
          'LLM responses stream response completed',
          details:
              'elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} chunks=${contentChunks.length} toolCalls=${calls.length} attempt=${attempt + 1}',
        );

        return LlmProviderResult(
          text: contentChunks.join(),
          toolCalls: calls,
          usage: usage,
        );
      } catch (e) {
        if (request.cancellationToken?.isCancelled == true ||
            e is LlmCancelledException) {
          AppLogService.instance.info(
            'LLM responses stream cancelled',
            details: 'endpoint=$endpoint model=${request.model}',
          );
          throw const LlmCancelledException();
        }

        final canRetry =
            _isRetryableNetworkError(e) &&
            contentChunks.isEmpty &&
            toolCalls.isEmpty &&
            attempt < 3;

        if (canRetry) {
          AppLogService.instance.warning(
            'LLM responses stream retryable network error',
            details: 'error=$e attempt=${attempt + 1}',
          );
          await _delayBeforeNetworkRetry(attempt, request.cancellationToken);
          continue;
        }
        rethrow;
      } finally {
        client.close();
      }
    }
    throw StateError('LLM responses stream failed after network retries.');
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
            'function': {'name': call.name, 'arguments': call.argumentsJson},
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
    return {'role': 'tool', 'tool_call_id': call.id, 'content': result};
  }

  Map<String, dynamic> _providerReasoningParams({
    required String baseUrl,
    required String model,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
  }) {
    final lower = model.toLowerCase();
    if (lower.startsWith('o1') || lower.startsWith('o3')) {
      return {
        'reasoning_effort': openAiReasoningEffort.toLowerCase() == 'medium'
            ? 'medium'
            : openAiReasoningEffort.toLowerCase() == 'high'
            ? 'high'
            : 'low',
      };
    }
    return const {};
  }

  bool _isRetryableNetworkError(Object error) {
    final name = error.runtimeType.toString();
    return name.contains('SocketException') ||
        name.contains('HttpException') ||
        name.contains('HandshakeException') ||
        name.contains('TlsException') ||
        name.contains('IOException') ||
        name.contains('ClientException');
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
