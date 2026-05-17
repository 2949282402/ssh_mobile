import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_tool_service.dart';
import 'app_log_service.dart';
import 'storage_service.dart';

class LlmChatService {
  final StorageService storageService;
  final AiToolService toolService;

  LlmChatService({
    required this.storageService,
    required this.toolService,
  });

  Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
  }) async {
    final resolvedApiKey = apiKey?.trim().isNotEmpty == true
        ? apiKey!.trim()
        : await storageService.getAiApiKey();
    if (resolvedApiKey == null || resolvedApiKey.isEmpty) {
      throw StateError('API key is not configured.');
    }
    _assertValidHeaderApiKey(resolvedApiKey);

    final endpoint = Uri.parse(_joinUrl(baseUrl, '/models'));
    final timeoutSeconds = await storageService.getAiRequestTimeoutSeconds();
    final client = HttpClient();
    final startedAt = DateTime.now();
    AppLogService.instance.info(
      'LLM models request sent',
      details: 'endpoint=$endpoint',
    );
    try {
      final request = await client.getUrl(endpoint).timeout(
            Duration(seconds: timeoutSeconds),
          );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $resolvedApiKey',
      );
      final response = await request.close().timeout(
            Duration(seconds: timeoutSeconds),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        AppLogService.instance.warning(
          'LLM models request failed',
          details:
              'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
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
        details:
            'count=${models.length} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds}',
      );
      return models;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM models request error',
        error: e,
        stackTrace: stackTrace,
        details: 'endpoint=$endpoint timeoutSeconds=$timeoutSeconds',
      );
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> send({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
  }) async {
    final buffer = StringBuffer();
    await for (final chunk in stream(
      messages: messages,
      modelOverride: modelOverride,
      requestToolApproval: requestToolApproval,
      onStats: onStats,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
    )) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  Stream<String> stream({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
  }) async* {
    final settings = await storageService.loadAiConnectionSettings();
    final runStartedAt = DateTime.now();
    final model = modelOverride?.trim().isNotEmpty == true
        ? modelOverride!.trim()
        : settings.model;
    final apiKey = await storageService.getAiApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      AppLogService.instance.warning('LLM request blocked: API key missing');
      throw StateError('API key is not configured.');
    }
    _assertValidHeaderApiKey(apiKey);
    AppLogService.instance.info(
      'LLM chat started',
      details:
          'baseUrl=${settings.baseUrl} model=$model userMessages=${messages.length} timeoutSeconds=${settings.timeoutSeconds}',
    );

    var workingMessages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': _systemPrompt,
      },
      ...messages,
    ];
    final estimatedBeforeCompression = estimateMessagesTokens(workingMessages);
    var compressed = false;
    if (estimatedBeforeCompression >= settings.contextWindowTokens * 0.9) {
      workingMessages = await _compressWorkingMessages(
        baseUrl: settings.baseUrl,
        apiKey: apiKey,
        model: model,
        messages: messages,
        contextWindowTokens: settings.contextWindowTokens,
        timeoutSeconds: settings.timeoutSeconds,
        deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
        deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
      );
      compressed = true;
    }

    final visibleOutput = StringBuffer();
    for (var round = 0;; round++) {
      cancellationToken?.throwIfCancelled();
      final content = StringBuffer();
      final chunkController = StreamController<String>();
      _StreamChatResult? streamedResponse;
      Object? streamedError;
      StackTrace? streamedStackTrace;

      // Bridge the HTTP SSE reader into an async* stream so the UI can render
      // answer text immediately while the final tool-call payload is collected.
      Future<void> pumpStream() async {
        try {
          streamedResponse = await _streamChatCompletion(
            baseUrl: settings.baseUrl,
            apiKey: apiKey,
            model: model,
            messages: workingMessages,
            tools: await toolService.toolDefinitions(),
            timeoutSeconds: settings.timeoutSeconds,
            deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
            deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
            cancellationToken: cancellationToken,
            onContent: (chunk) {
              cancellationToken?.throwIfCancelled();
              content.write(chunk);
              chunkController.add(chunk);
            },
          );
        } catch (e, stackTrace) {
          streamedError = e;
          streamedStackTrace = stackTrace;
        } finally {
          await chunkController.close();
        }
      }

      unawaited(pumpStream());

      await for (final chunk in chunkController.stream) {
        visibleOutput.write(chunk);
        yield chunk;
      }
      if (streamedError != null) {
        Error.throwWithStackTrace(streamedError!, streamedStackTrace!);
      }
      cancellationToken?.throwIfCancelled();
      final response = streamedResponse;
      if (response == null) {
        throw StateError('LLM stream ended without a response.');
      }
      _emitReasoningTrace(onTrace, response.reasoningContent);

      if (response.toolCalls.isEmpty) {
        final answer =
            content.toString().trim().isNotEmpty ? content.toString() : 'Done.';
        if (content.isEmpty) yield answer;
        AppLogService.instance.info(
          'LLM chat completed',
          details: 'rounds=${round + 1} answerChars=${answer.length}',
        );
        final elapsedMs =
            DateTime.now().difference(runStartedAt).inMilliseconds;
        final promptTokens = response.usage?.promptTokens ??
            estimateMessagesTokens(workingMessages);
        final completionTokens =
            response.usage?.completionTokens ?? estimateTextTokens(answer);
        onStats?.call(
          LlmRunStats(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens:
                response.usage?.totalTokens ?? promptTokens + completionTokens,
            elapsedMs: elapsedMs,
            usageFromProvider: response.usage != null,
            promptCacheHitTokens: response.usage?.promptCacheHitTokens,
            promptCacheMissTokens: response.usage?.promptCacheMissTokens,
            reasoningTokens: response.usage?.reasoningTokens,
            contextTokensBeforeCompression: estimatedBeforeCompression,
            contextWindowTokens: settings.contextWindowTokens,
            compressed: compressed,
          ),
        );
        return;
      }

      AppLogService.instance.info(
        'LLM requested tools',
        details:
            'round=${round + 1} tools=${response.toolCalls.map((call) => call.name).join(',')}',
      );
      final assistantToolMessage = <String, dynamic>{
        'role': 'assistant',
        'content': content.toString(),
        'tool_calls': [
          for (final call in response.toolCalls)
            {
              'id': call.id,
              'type': 'function',
              'function': {
                'name': call.name,
                'arguments': call.arguments,
              },
            },
        ],
      };

      // DeepSeek thinking models require reasoning_content to be passed back
      // unchanged on the tool round, even though it is not shown in the chat UI.
      if (response.reasoningContent.trim().isNotEmpty) {
        assistantToolMessage['reasoning_content'] = response.reasoningContent;
      }
      workingMessages.add(assistantToolMessage);
      for (final call in response.toolCalls) {
        cancellationToken?.throwIfCancelled();
        final arguments = _decodeArguments(call.arguments);
        onTrace?.call(
          LlmTraceEvent(
            kind: 'tool_request',
            title: 'Tool request: ${call.name}',
            content: _prettyJson({
              'tool': call.name,
              'arguments': arguments,
            }),
          ),
        );
        String result;
        try {
          var approvedWrite = false;
          final approvalRequest = toolService.approvalRequestFor(
            call.name,
            arguments,
          );
          if (approvalRequest != null) {
            if (requestToolApproval == null) {
              result = jsonEncode({
                'error':
                    'Write command requires user approval, but no approval UI is available.',
                'command': approvalRequest.command,
              });
              _emitToolResultTrace(onTrace, call.name, result);
              workingMessages.add({
                'role': 'tool',
                'tool_call_id': call.id,
                'content': result,
              });
              continue;
            }

            AppLogService.instance.info(
              'AI tool approval requested',
              details:
                  'tool=${call.name} connection=${approvalRequest.connectionName} command=${approvalRequest.command}',
            );
            final decision = await requestToolApproval(approvalRequest);
            cancellationToken?.throwIfCancelled();
            if (!decision.approved) {
              AppLogService.instance.warning(
                'AI tool approval rejected',
                details:
                    'tool=${call.name} connection=${approvalRequest.connectionName} abort=${decision.abort}',
              );
              result = jsonEncode({
                'error': 'User rejected the write command.',
                'command': approvalRequest.command,
                if (decision.feedback?.trim().isNotEmpty == true)
                  'feedback': decision.feedback!.trim(),
              });
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'approval',
                  title: 'Write command rejected',
                  content: _prettyJson({
                    'tool': call.name,
                    'server': approvalRequest.connectionName,
                    'command': approvalRequest.command,
                    'abort': decision.abort,
                    if (decision.feedback?.trim().isNotEmpty == true)
                      'feedback': decision.feedback!.trim(),
                  }),
                ),
              );
              _emitToolResultTrace(onTrace, call.name, result);
              workingMessages.add({
                'role': 'tool',
                'tool_call_id': call.id,
                'content': result,
              });
              if (decision.abort) {
                yield '\n\nWrite command rejected. Operation stopped. You can tell me what to do next.';
                return;
              }
              continue;
            }
            approvedWrite = true;
            onTrace?.call(
              LlmTraceEvent(
                kind: 'approval',
                title: 'Write command approved',
                content: _prettyJson({
                  'tool': call.name,
                  'server': approvalRequest.connectionName,
                  'command': approvalRequest.command,
                }),
              ),
            );
            AppLogService.instance.info(
              'AI tool approval accepted',
              details:
                  'tool=${call.name} connection=${approvalRequest.connectionName} command=${approvalRequest.command}',
            );
          }
          result = await toolService.execute(
            call.name,
            arguments,
            approvedWrite: approvedWrite,
          );
          cancellationToken?.throwIfCancelled();
        } on LlmCancelledException {
          rethrow;
        } catch (e) {
          result = jsonEncode({'error': e.toString()});
        }
        _emitToolResultTrace(onTrace, call.name, result);
        workingMessages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': result,
        });
      }
      final separator = _toolContinuationSeparator(visibleOutput.toString());
      if (separator.isNotEmpty) {
        visibleOutput.write(separator);
        yield separator;
      }
    }
  }

  Future<_StreamChatResult> _streamChatCompletion({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required int timeoutSeconds,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required void Function(String chunk) onContent,
    LlmCancellationToken? cancellationToken,
    bool includeUsage = true,
  }) async {
    final endpoint = Uri.parse(_joinUrl(baseUrl, '/chat/completions'));
    final client = HttpClient();
    cancellationToken?.onCancel(() => client.close(force: true));
    final startedAt = DateTime.now();
    final contentChunks = <String>[];
    final reasoningContent = StringBuffer();
    final toolCalls = <int, _StreamingToolCall>{};
    LlmTokenUsage? usage;
    AppLogService.instance.info(
      'LLM stream request sent',
      details: 'endpoint=$endpoint model=$model messages=${messages.length}',
    );
    try {
      cancellationToken?.throwIfCancelled();
      final request = await client.postUrl(endpoint).timeout(
            Duration(seconds: timeoutSeconds),
          );
      cancellationToken?.throwIfCancelled();
      final requestBody = <String, dynamic>{
        'model': model,
        'messages': messages,
        'tools': tools,
        'tool_choice': 'auto',
        'stream': true,
        if (includeUsage) 'stream_options': {'include_usage': true},
      };
      requestBody.addAll(
        _deepSeekThinkingParams(
          baseUrl: baseUrl,
          enabled: deepSeekThinkingEnabled,
          effort: deepSeekReasoningEffort,
        ),
      );
      final bodyBytes = utf8.encode(jsonEncode(requestBody));
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..contentType = ContentType.json;
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close().timeout(
            Duration(seconds: timeoutSeconds),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.transform(utf8.decoder).join();
        if (includeUsage &&
            response.statusCode == 400 &&
            (body.contains('stream_options') ||
                body.contains('include_usage'))) {
          AppLogService.instance.warning(
            'LLM stream usage unsupported, retrying without usage',
            details: 'endpoint=$endpoint model=$model bodyChars=${body.length}',
          );
          return _streamChatCompletion(
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: model,
            messages: messages,
            tools: tools,
            timeoutSeconds: timeoutSeconds,
            deepSeekThinkingEnabled: deepSeekThinkingEnabled,
            deepSeekReasoningEffort: deepSeekReasoningEffort,
            onContent: onContent,
            cancellationToken: cancellationToken,
            includeUsage: false,
          );
        }
        AppLogService.instance.warning(
          'LLM stream request failed',
          details:
              'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
        );
        throw StateError(
          'LLM stream failed (${response.statusCode}): $body',
        );
      }

      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        cancellationToken?.throwIfCancelled();
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
        final delta = (choices.first as Map<String, dynamic>)['delta'] as Map?;
        if (delta == null) continue;

        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          contentChunks.add(content);
          onContent(content);
        }

        // Some OpenAI-compatible providers stream hidden reasoning separately.
        // Keep it only for protocol continuity across tool calls.
        final reasoning = delta['reasoning_content'];
        if (reasoning is String && reasoning.isNotEmpty) {
          reasoningContent.write(reasoning);
        }

        // Tool-call names and JSON arguments may arrive in multiple SSE deltas.
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

      final calls = toolCalls.values
          .where((call) => call.name.trim().isNotEmpty)
          .toList();
      AppLogService.instance.info(
        'LLM stream response completed',
        details:
            'elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} chunks=${contentChunks.length} toolCalls=${calls.length}',
      );
      return _StreamChatResult(
        contentChunks: contentChunks,
        reasoningContent: reasoningContent.toString(),
        toolCalls: calls,
        usage: usage,
      );
    } catch (e, stackTrace) {
      if (cancellationToken?.isCancelled == true ||
          e is LlmCancelledException) {
        AppLogService.instance.info(
          'LLM stream cancelled',
          details: 'endpoint=$endpoint model=$model',
        );
        throw const LlmCancelledException();
      }
      AppLogService.instance.error(
        'LLM stream request error',
        error: e,
        stackTrace: stackTrace,
        details:
            'endpoint=$endpoint model=$model timeoutSeconds=$timeoutSeconds',
      );
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _decodeArguments(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    return {};
  }

  String _joinUrl(String baseUrl, String path) {
    final trimmedBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return '$trimmedBase$path';
  }

  void _emitReasoningTrace(
    void Function(LlmTraceEvent event)? onTrace,
    String reasoningContent,
  ) {
    final content = reasoningContent.trim();
    if (content.isEmpty) return;
    onTrace?.call(
      LlmTraceEvent(
        kind: 'reasoning',
        title: 'Deep thinking',
        content: content,
      ),
    );
  }

  void _emitToolResultTrace(
    void Function(LlmTraceEvent event)? onTrace,
    String toolName,
    String result,
  ) {
    onTrace?.call(
      LlmTraceEvent(
        kind: 'tool_result',
        title: 'Tool result: $toolName',
        content: _prettyJsonString(result),
      ),
    );
  }

  String _prettyJsonString(String text) {
    try {
      return _prettyJson(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }

  String _prettyJson(Object? value) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  String _toolContinuationSeparator(String visibleText) {
    if (visibleText.trim().isEmpty) return '';
    if (visibleText.endsWith('\n\n')) return '';
    if (visibleText.endsWith('\n')) return '\n';
    return '\n\n';
  }

  Future<List<Map<String, dynamic>>> _compressWorkingMessages({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required int contextWindowTokens,
    required int timeoutSeconds,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
  }) async {
    final lastUserIndex =
        messages.lastIndexWhere((message) => message['role'] == 'user');
    if (lastUserIndex <= 0) {
      return [
        {'role': 'system', 'content': _systemPrompt},
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
          'historyMessages=${history.length} estimatedTokens=${estimateTextTokens(transcript)} window=$contextWindowTokens',
    );
    final response = await _chatCompletion(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      messages: [
        {
          'role': 'system',
          'content':
              'Summarize this conversation for continuing an SSH/SFTP assistant chat. Preserve server names, paths, commands, decisions, approvals, errors, and unresolved tasks. Be concise but operationally complete.',
        },
        {'role': 'user', 'content': transcript},
      ],
      timeoutSeconds: timeoutSeconds,
      deepSeekThinkingEnabled: deepSeekThinkingEnabled,
      deepSeekReasoningEffort: deepSeekReasoningEffort,
    );
    final summary = _contentFromChatResponse(response);
    AppLogService.instance.info(
      'LLM context compression completed',
      details:
          'summaryTokens=${estimateTextTokens(summary)} tailMessages=${tail.length}',
    );
    return [
      {'role': 'system', 'content': _systemPrompt},
      {
        'role': 'assistant',
        'content': 'Conversation memory summary:\n$summary',
      },
      ...tail,
    ];
  }

  Future<Map<String, dynamic>> _chatCompletion({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required int timeoutSeconds,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
  }) async {
    final endpoint = Uri.parse(_joinUrl(baseUrl, '/chat/completions'));
    final client = HttpClient();
    try {
      final request = await client.postUrl(endpoint).timeout(
            Duration(seconds: timeoutSeconds),
          );
      final requestBody = <String, dynamic>{
        'model': model,
        'messages': messages,
      };
      requestBody.addAll(
        _deepSeekThinkingParams(
          baseUrl: baseUrl,
          enabled: deepSeekThinkingEnabled,
          effort: deepSeekReasoningEffort,
        ),
      );
      final bodyBytes = utf8.encode(jsonEncode(requestBody));
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..contentType = ContentType.json;
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close().timeout(
            Duration(seconds: timeoutSeconds),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'LLM compression failed (${response.statusCode}): $body',
        );
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM compression request error',
        error: e,
        stackTrace: stackTrace,
        details:
            'endpoint=$endpoint model=$model timeoutSeconds=$timeoutSeconds',
      );
      rethrow;
    } finally {
      client.close(force: true);
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

  Map<String, dynamic> _deepSeekThinkingParams({
    required String baseUrl,
    required bool enabled,
    required String effort,
  }) {
    if (!_isDeepSeekBaseUrl(baseUrl)) return const {};
    final params = <String, dynamic>{
      'thinking': {'type': enabled ? 'enabled' : 'disabled'},
    };
    if (enabled) {
      params['reasoning_effort'] = DeepSeekReasoningEffort.normalize(effort);
    }
    return params;
  }

  bool _isDeepSeekBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri?.host.toLowerCase().endsWith('deepseek.com') == true;
  }

  static int estimateMessagesTokens(List<Map<String, dynamic>> messages) {
    var total = 0;
    for (final message in messages) {
      total += 4;
      total += estimateTextTokens('${message['role'] ?? ''}');
      total += estimateTextTokens('${message['content'] ?? ''}');
    }
    return total;
  }

  static int estimateTextTokens(String text) {
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

class LlmCancellationToken {
  final List<void Function()> _callbacks = [];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = List<void Function()>.of(_callbacks);
    _callbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return;
    }
    _callbacks.add(callback);
  }

  void throwIfCancelled() {
    if (_cancelled) throw const LlmCancelledException();
  }
}

class LlmCancelledException implements Exception {
  const LlmCancelledException();

  @override
  String toString() => 'LLM request cancelled.';
}

class _StreamChatResult {
  final List<String> contentChunks;
  final String reasoningContent;
  final List<_StreamingToolCall> toolCalls;
  final LlmTokenUsage? usage;

  const _StreamChatResult({
    required this.contentChunks,
    required this.reasoningContent,
    required this.toolCalls,
    required this.usage,
  });
}

class LlmRunStats {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int elapsedMs;
  final bool usageFromProvider;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;
  final int contextTokensBeforeCompression;
  final int contextWindowTokens;
  final bool compressed;

  const LlmRunStats({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.elapsedMs,
    required this.usageFromProvider,
    this.promptCacheHitTokens,
    this.promptCacheMissTokens,
    this.reasoningTokens,
    required this.contextTokensBeforeCompression,
    required this.contextWindowTokens,
    required this.compressed,
  });
}

class LlmTraceEvent {
  final String kind;
  final String title;
  final String content;

  const LlmTraceEvent({
    required this.kind,
    required this.title,
    required this.content,
  });
}

class LlmTokenUsage {
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;

  const LlmTokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.promptCacheHitTokens,
    required this.promptCacheMissTokens,
    required this.reasoningTokens,
  });

  factory LlmTokenUsage.fromJson(Map<String, dynamic> json) {
    int? readInt(String key) {
      final value = json[key];
      return value is int ? value : null;
    }

    return LlmTokenUsage(
      promptTokens: readInt('prompt_tokens'),
      completionTokens: readInt('completion_tokens'),
      totalTokens: readInt('total_tokens'),
      promptCacheHitTokens: readInt('prompt_cache_hit_tokens'),
      promptCacheMissTokens: readInt('prompt_cache_miss_tokens'),
      reasoningTokens: (json['completion_tokens_details']
          as Map?)?['reasoning_tokens'] as int?,
    );
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

const String _systemPrompt = '''
You are an SSH Mobile assistant running inside the user's phone.
You can request tools to inspect the user's saved servers and perform safe read-only server operations.
Never ask for SSH passwords, private keys, or API keys.
Tools whose names start with client_ execute on the user's phone/app, not on SSH servers. Use client tools for local time, client device/network/battery info, clipboard, app settings, client alarms/reminders, and the current chat's WebView plain-text page reading, and say clearly that the action happened on the client.
The client_webview_get_page_text tool only reads visible plain text from the WebView bound to the current chat session. It does not read images, hidden DOM data, passwords, or cross-origin iframe contents.
Before using a server tool, identify the target server by name or id. If unclear, ask the user.
Servers may be Linux/Unix or Windows. Use the server's saved platform from list_servers/detect_os and never mix Linux commands with Windows commands. Use POSIX commands on Linux/Unix and explicit cmd /c or PowerShell read-only diagnostics on Windows.
Delete/remove commands are not supported through tools. Do not ask run_command to delete files, directories, services, registry keys, containers, or other resources.
Use run_command for read-only diagnostics by default. If the user explicitly asks for a server-changing command, request the command through run_command and wait for the app's human approval gate before it is executed.
Use generate_ops_report when the user asks for a health report, operations report, or broad server status review.
Summarize tool results clearly and mention which server/path/command you used.
''';
