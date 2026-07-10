import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/mcp/mcp_http_server.dart';
import 'package:ssh_mobile/services/mcp/mcp_json_rpc.dart';
import 'package:ssh_mobile/services/mcp/mcp_lifecycle_handler.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_settings.dart';
import 'package:ssh_mobile/services/mcp/mcp_tool_handler.dart';

void main() {
  group('McpHttpServer', () {
    late McpHttpServer server;
    late HttpClient client;

    setUp(() async {
      client = HttpClient();
      final executor = _FakeToolExecutor();
      server = await McpHttpServer.bind(
        host: '127.0.0.1',
        port: 0,
        token: 'secret',
        router: McpJsonRpcRouter(
          lifecycleHandler: const McpLifecycleHandler(),
          toolHandler: McpToolHandler(
            aiToolService: executor,
            settingsProvider: () => const McpServerSettings(token: 'secret'),
          ),
        ),
      );
    });

    tearDown(() async {
      client.close(force: true);
      await server.close();
    });

    Future<_JsonResponse> postJson(Map<String, dynamic> body) async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer secret');
      request.write(jsonEncode(body));
      final response = await request.close();
      final rawBody = await utf8.decoder.bind(response).join();
      return _JsonResponse(
        statusCode: response.statusCode,
        rawBody: rawBody,
        body: rawBody.isEmpty ? const {} : jsonDecode(rawBody) as Map,
      );
    }

    test('POST initialize returns JSON-RPC response', () async {
      final response = await postJson({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
      });

      expect(response.statusCode, 200);
      expect(response.body['result']['serverInfo']['name'], 'ssh_mobile');
    });

    test('POST notification returns accepted with no body', () async {
      final response = await postJson({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });

      expect(response.statusCode, 202);
      expect(response.rawBody, isEmpty);
    });

    test('POST ping works', () async {
      final response = await postJson({
        'jsonrpc': '2.0',
        'id': 'p',
        'method': 'ping',
      });

      expect(response.statusCode, 200);
      expect(response.body['result'], isEmpty);
    });

    test('POST tools/list returns MCP tool schemas', () async {
      final response = await postJson({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
      });

      expect(response.statusCode, 200);
      final tools = response.body['result']['tools'] as List;
      expect(tools.map((tool) => tool['name']), contains('list_servers'));
    });

    test('POST tools/call executes safe tool', () async {
      final response = await postJson({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'list_servers', 'arguments': {}},
      });

      expect(response.statusCode, 200);
      final result = response.body['result'] as Map;
      expect(result['isError'], isFalse);
      expect(result['content'][0]['text'], contains('"servers"'));
    });

    test('POST tools/call for write tool returns approval_required', () async {
      final response = await postJson({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'connectionId': 'server-1', 'command': 'uptime'},
        },
      });

      expect(response.statusCode, 200);
      final result = response.body['result'] as Map;
      expect(result['isError'], isTrue);
      expect(result['content'][0]['text'], contains('approval_required'));
    });

    test('GET /mcp returns 405', () async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      );
      final response = await request.close();

      expect(response.statusCode, 405);
    });

    test('wrong path returns 404', () async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/wrong'),
      );
      final response = await request.close();

      expect(response.statusCode, 404);
    });

    test('invalid token returns 401', () async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer wrong');
      request.write(jsonEncode({'jsonrpc': '2.0', 'id': 5, 'method': 'ping'}));

      final response = await request.close();

      expect(response.statusCode, 401);
    });
  });
}

class _JsonResponse {
  final int statusCode;
  final String rawBody;
  final Map body;

  const _JsonResponse({
    required this.statusCode,
    required this.rawBody,
    required this.body,
  });
}

class _FakeToolExecutor implements AiToolExecutor {
  var executedTools = <String>[];

  @override
  Future<List<AiTool>> tools() async {
    return [
      AiTool(
        name: 'list_servers',
        description: 'List saved servers.',
        properties: const {},
        handler: (_) async => jsonEncode({'servers': []}),
      ),
      AiTool(
        name: 'run_command',
        description: 'Run a command.',
        properties: const {
          'connectionId': {'type': 'string'},
          'command': {'type': 'string'},
        },
        required: const ['connectionId', 'command'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (_) async => jsonEncode({'ok': true}),
      ),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    return (await tools()).map((tool) => tool.definition).toList();
  }

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    return null;
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    executedTools.add(name);
    return jsonEncode({'servers': []});
  }

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
    return const AiCommandReview.readOnly();
  }
}
