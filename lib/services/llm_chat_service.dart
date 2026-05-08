import 'dart:convert';
import 'dart:io';

import 'ai_tool_service.dart';
import 'storage_service.dart';

class LlmChatService {
  final StorageService storageService;
  final AiToolService toolService;

  LlmChatService({
    required this.storageService,
    required this.toolService,
  });

  Future<String> send({
    required List<Map<String, dynamic>> messages,
  }) async {
    final settings = await storageService.loadAiConnectionSettings();
    final apiKey = await storageService.getAiApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('API key is not configured.');
    }

    final workingMessages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': _systemPrompt,
      },
      ...messages,
    ];

    for (var round = 0; round < 4; round++) {
      final response = await _chatCompletion(
        baseUrl: settings.baseUrl,
        apiKey: apiKey,
        model: settings.model,
        messages: workingMessages,
        tools: toolService.toolDefinitions(),
      );
      final message = ((response['choices'] as List).first as Map)['message']
          as Map<String, dynamic>;
      final toolCalls = message['tool_calls'] as List<dynamic>?;
      if (toolCalls == null || toolCalls.isEmpty) {
        return (message['content'] as String?)?.trim().isNotEmpty == true
            ? message['content'] as String
            : 'Done.';
      }

      workingMessages.add(message);
      for (final rawCall in toolCalls) {
        final call = rawCall as Map<String, dynamic>;
        final function = call['function'] as Map<String, dynamic>;
        final name = function['name'] as String;
        final arguments = _decodeArguments(function['arguments']);
        String result;
        try {
          result = await toolService.execute(name, arguments);
        } catch (e) {
          result = jsonEncode({'error': e.toString()});
        }
        workingMessages.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'content': result,
        });
      }
    }

    return 'The model requested too many tool rounds. Please narrow the task.';
  }

  Future<Map<String, dynamic>> _chatCompletion({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
  }) async {
    final endpoint = Uri.parse(_joinUrl(baseUrl, '/chat/completions'));
    final client = HttpClient();
    try {
      final request = await client.postUrl(endpoint).timeout(
            const Duration(seconds: 15),
          );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(
        jsonEncode({
          'model': model,
          'messages': messages,
          'tools': tools,
          'tool_choice': 'auto',
        }),
      );
      final response = await request.close().timeout(
            const Duration(seconds: 45),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'LLM request failed (${response.statusCode}): $body',
        );
      }
      return jsonDecode(body) as Map<String, dynamic>;
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

const String _systemPrompt = '''
You are an SSH Mobile assistant running inside the user's phone.
You can request tools to inspect the user's saved servers and perform safe read-only server operations.
Never ask for SSH passwords, private keys, or API keys.
Before using a server tool, identify the target server by name or id. If unclear, ask the user.
Use run_command only for read-only diagnostics. Do not attempt destructive commands.
Summarize tool results clearly and mention which server/path/command you used.
''';
