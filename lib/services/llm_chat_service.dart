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

    final endpoint = Uri.parse(_joinUrl(baseUrl, '/models'));
    final client = HttpClient();
    final startedAt = DateTime.now();
    AppLogService.instance.info(
      'LLM models request sent',
      details: 'endpoint=$endpoint',
    );
    try {
      final request = await client.getUrl(endpoint).timeout(
            const Duration(seconds: 15),
          );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $resolvedApiKey',
      );
      final response = await request.close().timeout(
            const Duration(seconds: 30),
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
        details: 'endpoint=$endpoint',
      );
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> send({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
  }) async {
    final buffer = StringBuffer();
    await for (final chunk in stream(
      messages: messages,
      modelOverride: modelOverride,
    )) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  Stream<String> stream({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
  }) async* {
    final settings = await storageService.loadAiConnectionSettings();
    final model = modelOverride?.trim().isNotEmpty == true
        ? modelOverride!.trim()
        : settings.model;
    final apiKey = await storageService.getAiApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      AppLogService.instance.warning('LLM request blocked: API key missing');
      throw StateError('API key is not configured.');
    }
    AppLogService.instance.info(
      'LLM chat started',
      details:
          'baseUrl=${settings.baseUrl} model=$model userMessages=${messages.length}',
    );

    final workingMessages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': _systemPrompt,
      },
      ...messages,
    ];

    for (var round = 0; round < 10; round++) {
      final content = StringBuffer();
      final chunkController = StreamController<String>();
      _StreamChatResult? streamedResponse;
      Object? streamedError;
      StackTrace? streamedStackTrace;
      Future<void> pumpStream() async {
        try {
          streamedResponse = await _streamChatCompletion(
            baseUrl: settings.baseUrl,
            apiKey: apiKey,
            model: model,
            messages: workingMessages,
            tools: toolService.toolDefinitions(),
            onContent: (chunk) {
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
        yield chunk;
      }
      if (streamedError != null) {
        Error.throwWithStackTrace(streamedError!, streamedStackTrace!);
      }
      final response = streamedResponse;
      if (response == null) {
        throw StateError('LLM stream ended without a response.');
      }

      if (response.toolCalls.isEmpty) {
        final answer =
            content.toString().trim().isNotEmpty ? content.toString() : 'Done.';
        if (content.isEmpty) yield answer;
        AppLogService.instance.info(
          'LLM chat completed',
          details: 'rounds=${round + 1} answerChars=${answer.length}',
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
      if (response.reasoningContent.trim().isNotEmpty) {
        assistantToolMessage['reasoning_content'] = response.reasoningContent;
      }
      workingMessages.add(assistantToolMessage);
      for (final call in response.toolCalls) {
        final arguments = _decodeArguments(call.arguments);
        String result;
        try {
          result = await toolService.execute(call.name, arguments);
        } catch (e) {
          result = jsonEncode({'error': e.toString()});
        }
        workingMessages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': result,
        });
      }
    }

    AppLogService.instance.warning('LLM chat stopped: too many tool rounds');
    yield 'The model requested too many tool rounds. Please narrow the task.';
  }

  Future<_StreamChatResult> _streamChatCompletion({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required void Function(String chunk) onContent,
  }) async {
    final endpoint = Uri.parse(_joinUrl(baseUrl, '/chat/completions'));
    final client = HttpClient();
    final startedAt = DateTime.now();
    final contentChunks = <String>[];
    final reasoningContent = StringBuffer();
    final toolCalls = <int, _StreamingToolCall>{};
    AppLogService.instance.info(
      'LLM stream request sent',
      details: 'endpoint=$endpoint model=$model messages=${messages.length}',
    );
    try {
      final request = await client.postUrl(endpoint).timeout(
            const Duration(seconds: 15),
          );
      final bodyBytes = utf8.encode(
        jsonEncode({
          'model': model,
          'messages': messages,
          'tools': tools,
          'tool_choice': 'auto',
          'stream': true,
        }),
      );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..contentType = ContentType.json;
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close().timeout(
            const Duration(seconds: 45),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.transform(utf8.decoder).join();
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
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final data = trimmed.substring(5).trim();
        if (data == '[DONE]') break;
        if (data.isEmpty) continue;

        final decoded = jsonDecode(data) as Map<String, dynamic>;
        final choices = decoded['choices'] as List<dynamic>? ?? const [];
        if (choices.isEmpty) continue;
        final delta = (choices.first as Map<String, dynamic>)['delta'] as Map?;
        if (delta == null) continue;

        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          contentChunks.add(content);
          onContent(content);
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
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM stream request error',
        error: e,
        stackTrace: stackTrace,
        details: 'endpoint=$endpoint model=$model',
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
}

class _StreamChatResult {
  final List<String> contentChunks;
  final String reasoningContent;
  final List<_StreamingToolCall> toolCalls;

  const _StreamChatResult({
    required this.contentChunks,
    required this.reasoningContent,
    required this.toolCalls,
  });
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
Before using a server tool, identify the target server by name or id. If unclear, ask the user.
Use run_command only for read-only diagnostics. Do not attempt destructive commands.
Summarize tool results clearly and mention which server/path/command you used.
''';
