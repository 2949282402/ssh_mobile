import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_tool_service.dart';
import 'app_log_service.dart';
import 'storage_service.dart';
import 'tool_secret_policy.dart';

abstract interface class LlmClientAdapter {
  Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
  });

  Future<String> send({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
  });

  Stream<String> stream({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    Set<String>? allowedTools,
    bool forceContextCompression = false,
  });
}

/// OpenAI 鍏煎 LLM 娴佸紡瀵硅瘽鏈嶅姟銆?
///
/// 鏍稿績鑳藉姏锛?
/// 1. SSE 娴佸紡瑙ｆ瀽 鈥?鎵嬪姩瑙ｆ瀽 data: 琛岋紝绱Н tool_calls delta
/// 2. 澶氳疆宸ュ叿璋冪敤寰幆 鈥?鑷姩鎵ц宸ュ叿骞惰繑鍥炵粨鏋滅粰 LLM
/// 3. 涓婁笅鏂囧帇缂?鈥?Token 瓒呰繃 90% 绐楀彛鏃惰嚜鍔ㄥ帇缂╀腑闂磋疆娆?
/// 4. DeepSeek 鎵╁睍 鈥?reasoning_content 閫忎紶銆乼hinking 鍙傛暟
///
/// 浣跨敤 dart:io HttpClient 鑰岄潪绗笁鏂?HTTP 鍖咃紝鐩存帴閫愯璇诲彇 response body
/// 瀹炵幇鐪熷疄娴佸紡娓叉煋锛堣€屼笉鏄瓑寰呭畬鏁村搷搴旓級銆?
class LlmChatService implements LlmClientAdapter {
  final StorageService storageService;
  final AiToolExecutor toolService;
  final ToolSecretPolicy _toolSecretPolicy = const ToolSecretPolicy();

  LlmChatService({
    required this.storageService,
    required this.toolService,
  });

  @override
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

  @override
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

  /// 娴佸紡鑱婂ぉ鍏ュ彛銆傝繑鍥?`Stream<String>` 瀹炵幇鎵撳瓧鏈烘晥鏋溿€?
  ///
  /// 鏍稿績寰幆锛?
  /// 1. 妫€鏌ヤ笂涓嬫枃绐楀彛锛?90% 鍒欏帇缂╋級
  /// 2. 鍙戦€?SSE 璇锋眰骞堕€?chunk 浜у嚭鏂囨湰
  /// 3. 濡傛灉 LLM 杩斿洖 tool_calls 鈫?鎵ц宸ュ叿锛堝惈瀹℃壒娴佺▼锛夆啋 杩藉姞缁撴灉 鈫?鍥炲埌姝ラ 2
  /// 4. 濡傛灉 LLM 杩斿洖鏅€氭枃鏈?鈫?浜у嚭瀹屾暣绛旀骞惰繑鍥?
  @override
  Stream<String> stream({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    Set<String>? allowedTools,
    bool forceContextCompression = false,
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
          'baseUrl=${settings.baseUrl} model=$model userMessages=${messages.length} timeoutSeconds=${settings.timeoutSeconds} forceContextCompression=$forceContextCompression',
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
    final shouldCompressFromUsageThreshold =
        estimatedBeforeCompression >= settings.contextWindowTokens * 0.9;
    if (shouldCompressFromUsageThreshold || forceContextCompression) {
      workingMessages = await _compressWorkingMessages(
        baseUrl: settings.baseUrl,
        apiKey: apiKey,
        model: model,
        messages: messages,
        contextWindowTokens: settings.contextWindowTokens,
        timeoutSeconds: settings.timeoutSeconds,
        deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
        deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
        openAiReasoningEffort: settings.openAiReasoningEffort,
      );
      compressed = true;
      if (forceContextCompression && !shouldCompressFromUsageThreshold) {
        AppLogService.instance.info(
          'LLM context compression forced',
          details:
              'baseTokens=$estimatedBeforeCompression window=${settings.contextWindowTokens}',
        );
      }
    }
    final toolDefinitions = await toolService.toolDefinitions();
    final normalizedAllowedTools = _normalizeToolNames(allowedTools);
    final filteredToolDefinitions = normalizedAllowedTools == null
        ? toolDefinitions
        : _filterToolDefinitions(toolDefinitions, normalizedAllowedTools);
    if (normalizedAllowedTools == null) {
      AppLogService.instance.info(
        'LLM tool filter skipped',
        details: 'availableTools=${toolDefinitions.length}',
      );
    } else {
      AppLogService.instance.info(
        'LLM tool definitions filtered',
        details:
            'requestedTools=${normalizedAllowedTools.length} availableTools=${toolDefinitions.length} filteredTools=${filteredToolDefinitions.length}',
      );
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
            tools: filteredToolDefinitions,
            timeoutSeconds: settings.timeoutSeconds,
            deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
            deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
            openAiReasoningEffort: settings.openAiReasoningEffort,
            cancellationToken: cancellationToken,
            includeTools: filteredToolDefinitions.isNotEmpty,
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
              'arguments': _toolSecretPolicy.redactValue(arguments),
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
                    'This tool action requires user approval, but no approval UI is available.',
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
                'error': 'User rejected the requested tool action.',
                'command': approvalRequest.command,
                if (decision.feedback?.trim().isNotEmpty == true)
                  'feedback': decision.feedback!.trim(),
              });
              onTrace?.call(
                LlmTraceEvent(
                  kind: 'approval',
                  title: 'Tool action rejected',
                  content: _prettyJson({
                    'tool': call.name,
                    'approvalType': approvalRequest.approvalType,
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
                yield '\n\nTool action rejected. Operation stopped. You can tell me what to do next.';
                return;
              }
              continue;
            }
            approvedWrite = true;
            onTrace?.call(
              LlmTraceEvent(
                kind: 'approval',
                title: 'Tool action approved',
                content: _prettyJson({
                  'tool': call.name,
                  'approvalType': approvalRequest.approvalType,
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
          result = jsonEncode({
            'error': _toolSecretPolicy.redactText(e.toString()),
          });
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

  /// 搴曞眰 SSE 娴佸紡璇锋眰銆?
  ///
  /// HTTP POST -> SSE data: 琛岃В鏋?-> 鍐呭/tool_calls/reasoning 鎻愬彇 -> 缁撴灉杩斿洖銆?
  ///
  /// 鍏抽敭璁捐锛?
  /// - tool_calls 鎸?index 鍦?`Map<int, _StreamingToolCall>` 涓疮绉?
  ///   锛堝洜涓?function.arguments JSON 瀛楃涓插垎澶氫釜 delta 鍧椾紶杈擄級
  /// - reasoning_content 浣跨敤 StringBuffer 绱Н
  /// - stream_options.include_usage 鍦ㄦ渶鍚庝竴涓?chunk 鍚庤幏鍙?token 鐢ㄩ噺
  /// - 濡傛灉 stream_options 涓嶅彈鏀寔锛?00 閿欒锛夛紝鑷姩闄嶇骇閲嶈瘯涓嶅甫 usage 鐨勮姹?
  Future<_StreamChatResult> _streamChatCompletion({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required int timeoutSeconds,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
    required void Function(String chunk) onContent,
    LlmCancellationToken? cancellationToken,
    bool includeUsage = true,
    bool includeTools = true,
    bool includeReasoningParams = true,
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
      final useTools = includeTools && tools.isNotEmpty;
      final requestBody = <String, dynamic>{
        'model': model,
        'messages': messages,
        'stream': true,
        if (useTools) ...{
          'tools': tools,
          'tool_choice': 'auto',
        },
        if (includeUsage) 'stream_options': {'include_usage': true},
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
            openAiReasoningEffort: openAiReasoningEffort,
            onContent: onContent,
            cancellationToken: cancellationToken,
            includeUsage: false,
            includeTools: includeTools,
            includeReasoningParams: includeReasoningParams,
          );
        }
        if (includeTools && _looksLikeToolUnsupportedError(body)) {
          AppLogService.instance.warning(
            'LLM stream tools unsupported, retrying without tools',
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
            openAiReasoningEffort: openAiReasoningEffort,
            onContent: onContent,
            cancellationToken: cancellationToken,
            includeUsage: includeUsage,
            includeTools: false,
            includeReasoningParams: includeReasoningParams,
          );
        }
        if (includeReasoningParams &&
            _looksLikeReasoningParamUnsupportedError(body)) {
          AppLogService.instance.warning(
            'LLM reasoning params unsupported, retrying without them',
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
            openAiReasoningEffort: openAiReasoningEffort,
            onContent: onContent,
            cancellationToken: cancellationToken,
            includeUsage: includeUsage,
            includeTools: includeTools,
            includeReasoningParams: false,
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
    return resolveOpenAiCompatibleUrl(baseUrl, path);
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

  bool _looksLikeToolUnsupportedError(String body) {
    return looksLikeToolUnsupportedError(body);
  }

  Set<String>? _normalizeToolNames(Set<String>? tools) {
    if (tools == null) return null;
    final normalized = <String>{};
    for (final tool in tools) {
      final name = tool.trim().toLowerCase();
      if (name.isNotEmpty) normalized.add(name);
    }
    return normalized;
  }

  List<Map<String, dynamic>> _filterToolDefinitions(
    List<Map<String, dynamic>> definitions,
    Set<String> allowedTools,
  ) {
    if (allowedTools.isEmpty) return const [];
    final filtered = <Map<String, dynamic>>[];
    for (final definition in definitions) {
      final name = _toolNameFromDefinition(definition);
      if (name != null && allowedTools.contains(name.toLowerCase())) {
        filtered.add(definition);
      }
    }
    return filtered;
  }

  String? _toolNameFromDefinition(Map<String, dynamic> definition) {
    final function = definition['function'];
    if (function is! Map) return null;
    final name = function['name'];
    return name is String ? name : null;
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
      return _prettyJson(_toolSecretPolicy.redactValue(jsonDecode(text)));
    } catch (_) {
      return _toolSecretPolicy.redactText(text);
    }
  }

  String _prettyJson(Object? value) {
    return const JsonEncoder.withIndent('  ')
        .convert(_toolSecretPolicy.redactValue(value));
  }

  String _toolContinuationSeparator(String visibleText) {
    if (visibleText.trim().isEmpty) return '';
    if (visibleText.endsWith('\n\n')) return '';
    if (visibleText.endsWith('\n')) return '\n';
    return '\n\n';
  }

  /// 涓婁笅鏂囧帇缂╋細褰撴秷鎭及绠?Token 瓒呰繃 contextWindow * 90% 鏃惰Е鍙戙€?
  /// 灏嗛櫎鏈€鍚庝竴鏉?user 娑堟伅澶栫殑鍘嗗彶鍙戠粰 LLM 鍋氭憳瑕侊紝
  /// 淇濈暀鏈嶅姟鍣ㄥ悕銆佽矾寰勩€佸懡浠ゃ€佸喅绛栫瓑鍏抽敭鎿嶄綔淇℃伅銆?
  Future<List<Map<String, dynamic>>> _compressWorkingMessages({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required int contextWindowTokens,
    required int timeoutSeconds,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
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
      openAiReasoningEffort: openAiReasoningEffort,
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
    required String openAiReasoningEffort,
    bool includeReasoningParams = true,
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
      final response = await request.close().timeout(
            Duration(seconds: timeoutSeconds),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (includeReasoningParams &&
            response.statusCode == 400 &&
            _looksLikeReasoningParamUnsupportedError(body)) {
          AppLogService.instance.warning(
            'LLM compression reasoning params unsupported, retrying without them',
            details: 'endpoint=$endpoint model=$model bodyChars=${body.length}',
          );
          return _chatCompletion(
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: model,
            messages: messages,
            timeoutSeconds: timeoutSeconds,
            deepSeekThinkingEnabled: deepSeekThinkingEnabled,
            deepSeekReasoningEffort: deepSeekReasoningEffort,
            openAiReasoningEffort: openAiReasoningEffort,
            includeReasoningParams: false,
          );
        }
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

  /// 绠€鍗曠殑 Token 浼扮畻锛欰SCII 4 瀛楃 = 1 token锛岄潪 ASCII = 1 token 姣忓瓧绗?
  /// 绮剧‘搴︾害 80-85%锛屼笉渚濊禆 tiktoken锛圖art 鐢熸€佷笉鎴愮啛锛?
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

/// 鍙彇娑堜护鐗岋細璋冪敤 cancel() 鍚庯紝鎵€鏈?isCancelled/throwIfCancelled 鐐圭珛鍗冲搷搴斻€?
/// onCancel 鐢ㄤ簬閲婃斁璧勬簮锛堝叧闂?HttpClient 杩炴帴锛夈€?
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
You can request tools to inspect the user's saved servers and perform safe operational actions through the app.
Never ask for, retrieve, echo, summarize, or store SSH passwords, private keys, tokens, API keys, environment dumps, or secret-bearing file contents.
Tools whose names start with client_ execute on the user's phone/app, not on SSH servers. Use client tools for local time, client device/network/battery info, clipboard, logs, app backup export/import, app settings, client alarms/reminders, and the current chat's WebView plain-text page reading, and say clearly that the action happened on the client.
When the user asks to summarize an experience and persist it as a Skill (including Chinese phrases like "总结经验", "总结一下", "复盘", "沉淀经验", "记录经验", "写入经验", "写到skill", "保存为 Skill", "保存为skill", "存经验", "更新 skill", "持久化经验", or explicit intent to save the current lesson/experience), treat this as a mandatory tool flow:
1) Call client_save_experience_skill exactly once before sending any final assistant narrative.
2) Always send `summary` (concise, non-sensitive, usually 1-3 short paragraphs).
3) Send `content` with concrete steps/caveats/commands if available; optional if unavailable.
4) Send `title` if obvious; otherwise infer one from the request.
5) Never include secrets or credential-like data in summary/title/content.
6) If the tool call fails, do not continue with a normal summary response—report the failure and ask to retry after the tool result.
Use client_get_permission_status when the user needs notification, background-run, or Android battery-optimization diagnostics on the client device.
Use client_query_logs and client_get_log_counts to inspect recent redacted client logs for SSH, SFTP, LLM, AI tools, WebView, or background issues.
Use get_server_details to inspect saved non-sensitive server metadata. Never ask for secrets because saved server credentials are not accessible to you.
The web_search tool is also client-side: it uses the WebView bound to the current chat session to load a public search page and returns readable search result titles, URLs, and snippets.
When web_search is available, use it before answering questions about current events, latest facts, news, prices, versions, schedules, or other external information, unless the user asks not to search.
The client_webview_get_page_text tool only reads visible plain text from the WebView bound to the current chat session. It does not read images, hidden DOM data, passwords, or cross-origin iframe contents.
Use client_webview_get_state and client_webview_navigate to inspect or navigate the WebView bound to the current chat session without interrupting an active AI-browsing lock.
Before using a server tool, identify the target server by name or id. If unclear, ask the user.
Servers may be Linux/Unix or Windows. Use the server's saved platform from list_servers/detect_os and never mix Linux commands with Windows commands. Use POSIX commands on Linux/Unix and explicit cmd /c or PowerShell read-only diagnostics on Windows.
Delete/remove commands are not supported through run_command. Do not ask run_command to delete files, directories, services, registry keys, containers, or other resources.
run_command is also blocked from reading environment dumps or secret-bearing paths. Use it for read-only diagnostics by default. If the user explicitly asks for a server-changing command, request the command through run_command and wait for the app's human approval gate before it is executed.
Use the ssh_* tools for session lifecycle and terminal-history metadata. Do not expect to see raw terminal output history.
Use the sftp_* tools for remote file operations. Secret-bearing paths are blocked. Use sftp_download_file when the user wants to save a remote file onto the client device. Use sftp_write_text, sftp_upload_local_file, sftp_create_directory, sftp_rename_entry, and sftp_delete_entry only when the user explicitly wants those remote changes, and expect the app to require approval before execution.
Use the monitor_* tools for app-scoped server monitoring state, health snapshots, samples, alerts, ports, and application views instead of reimplementing monitoring with ad hoc commands.
Use app_get_operational_settings and app_update_operational_settings for tool-related app settings. Never ask for API keys because you cannot read or manage them.
Use generate_ops_report when the user asks for a health report, operations report, or broad server status review.
Summarize tool results clearly and mention which server/path/command you used.
''';
