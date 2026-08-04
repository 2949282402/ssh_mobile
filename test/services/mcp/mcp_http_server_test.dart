import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/mcp/mcp_http_server.dart';
import 'package:ssh_mobile/services/mcp/mcp_activity.dart';
import 'package:ssh_mobile/services/mcp/mcp_approval_queue.dart';
import 'package:ssh_mobile/services/mcp/mcp_json_rpc.dart';
import 'package:ssh_mobile/services/mcp/mcp_lifecycle_handler.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_settings.dart';
import 'package:ssh_mobile/services/mcp/mcp_tool_handler.dart';

void main() {
  group('McpHttpServer', () {
    late McpHttpServer server;
    late HttpClient client;
    late _MemoryActivityRepository activityRepository;

    setUp(() async {
      client = HttpClient();
      activityRepository = _MemoryActivityRepository();
      final activityRecorder = McpActivityRecorder(activityRepository);
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
            activityRecorder: activityRecorder,
          ),
        ),
        activityRecorder: activityRecorder,
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

      await Future<void>.delayed(Duration.zero);
      final activity = activityRepository.records.last;
      expect(activity.kind, McpActivityKind.tool);
      expect(activity.method, 'tools/call');
      expect(activity.toolName, 'list_servers');
      expect(activity.outcome, McpActivityOutcome.success);
      expect(activity.policyReason, 'tool_not_configured_for_secondary_review');
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

      await Future<void>.delayed(Duration.zero);
      final activity = activityRepository.records.last;
      expect(activity.kind, McpActivityKind.tool);
      expect(activity.toolName, 'run_command');
      expect(activity.outcome, McpActivityOutcome.denied);
      expect(activity.policyReason, isNotEmpty);
    });

    test(
      'MCP write tool waits for console approval before executing',
      () async {
        final queue = McpApprovalQueue();
        final executor = _FakeToolExecutor();
        final handler = McpToolHandler(
          aiToolService: executor,
          settingsProvider: () => const McpServerSettings(token: 'secret'),
          approvalQueue: queue,
        );

        final responseFuture = handler.handle(
          const McpJsonRpcRequest(
            id: 'approval-test',
            hasId: true,
            method: 'tools/call',
            params: {
              'name': 'run_command',
              'arguments': {'connectionId': 'server-1', 'command': 'uptime'},
            },
          ),
        );

        await _waitFor(() => queue.pending.isNotEmpty);
        expect(queue.pending.single.request.toolName, 'run_command');
        await queue.approve(queue.pending.single.id);

        final response = await responseFuture;
        expect(response.result, isA<Map>());
        final result = response.result! as Map;
        expect(result['isError'], isFalse);
        expect(executor.executedTools, contains('run_command'));
        queue.dispose();
      },
    );

    test('trustedAgent executes a bound write without queueing', () async {
      final queue = McpApprovalQueue();
      final executor = _FakeToolExecutor();
      final handler = McpToolHandler(
        aiToolService: executor,
        settingsProvider: () => const McpServerSettings(
          token: 'secret',
          approvalMode: McpApprovalMode.trustedAgent,
        ),
        approvalQueue: queue,
      );

      final response = await handler.handle(
        const McpJsonRpcRequest(
          id: 'trusted-test',
          hasId: true,
          method: 'tools/call',
          params: {
            'name': 'run_command',
            'arguments': {'connectionId': 'server-1', 'command': 'uptime'},
          },
        ),
      );

      final result = response.result! as Map;
      expect(result['isError'], isFalse);
      expect(queue.pending, isEmpty);
      expect(executor.executedTools, contains('run_command'));
      queue.dispose();
    });

    test(
      'review mode executes an unconfigured tool without queueing',
      () async {
        final queue = McpApprovalQueue();
        final executor = _FakeToolExecutor();
        final handler = McpToolHandler(
          aiToolService: executor,
          settingsProvider: () => const McpServerSettings(
            token: 'secret',
            secondaryReviewTools: {},
          ),
          approvalQueue: queue,
        );

        final response = await handler.handle(
          const McpJsonRpcRequest(
            id: 'unconfigured-test',
            hasId: true,
            method: 'tools/call',
            params: {
              'name': 'run_command',
              'arguments': {'connectionId': 'server-1', 'command': 'uptime'},
            },
          ),
        );

        final result = response.result! as Map;
        expect(result['isError'], isFalse);
        expect(queue.pending, isEmpty);
        expect(executor.executedTools, contains('run_command'));
        queue.dispose();
      },
    );

    test(
      'trustedAgent rejects a bound request without a target guard',
      () async {
        final executor = _FakeExecutorWithoutGuard();
        final handler = McpToolHandler(
          aiToolService: executor,
          settingsProvider: () => const McpServerSettings(
            token: 'secret',
            approvalMode: McpApprovalMode.trustedAgent,
          ),
        );

        final response = await handler.handle(
          const McpJsonRpcRequest(
            id: 'missing-guard-test',
            hasId: true,
            method: 'tools/call',
            params: {
              'name': 'run_command',
              'arguments': {'connectionId': 'server-1', 'command': 'uptime'},
            },
          ),
        );

        final result = response.result! as Map;
        expect(result['isError'], isTrue);
        expect(
          result['content'][0]['text'],
          contains('approval_guard_unavailable'),
        );
      },
    );

    test(
      'hidden tools cannot be called even when their name is known',
      () async {
        final executor = _FakeToolExecutor();
        final handler = McpToolHandler(
          aiToolService: executor,
          settingsProvider: () => const McpServerSettings(
            token: 'secret',
            approvalMode: McpApprovalMode.trustedAgent,
          ),
        );

        final response = await handler.handle(
          const McpJsonRpcRequest(
            id: 'hidden-test',
            hasId: true,
            method: 'tools/call',
            params: {'name': 'client_set_plan_mode', 'arguments': {}},
          ),
        );

        final result = response.result! as Map;
        expect(result['isError'], isTrue);
        expect(result['content'][0]['text'], contains('tool_not_available'));
        expect(executor.executedTools, isNot(contains('client_set_plan_mode')));
      },
    );

    test(
      'unexposed tools are omitted from list and rejected before approval',
      () async {
        final queue = McpApprovalQueue();
        final executor = _FakeToolExecutor();
        const settings = McpServerSettings(
          token: 'secret',
          exposedTools: {'list_servers'},
          exposureToolsConfigured: true,
        );
        final handler = McpToolHandler(
          aiToolService: executor,
          settingsProvider: () => settings,
          approvalQueue: queue,
        );

        final listed = await handler.handle(
          const McpJsonRpcRequest(
            id: 'list-unexposed',
            hasId: true,
            method: 'tools/list',
          ),
        );
        final names = (listed.result! as Map)['tools'] as List;
        expect(names.map((tool) => tool['name']), contains('list_servers'));
        expect(
          names.map((tool) => tool['name']),
          isNot(contains('run_command')),
        );

        final called = await handler.handle(
          const McpJsonRpcRequest(
            id: 'call-unexposed',
            hasId: true,
            method: 'tools/call',
            params: {
              'name': 'run_command',
              'arguments': {'connectionId': 'server-1', 'command': 'uptime'},
            },
          ),
        );
        final result = called.result! as Map;
        expect(result['isError'], isTrue);
        expect(result['content'][0]['text'], contains('tool_not_available'));
        expect(result['content'][0]['text'], contains('not_exposed_by_user'));
        expect(queue.pending, isEmpty);
        expect(executor.executedTools, isNot(contains('run_command')));
        queue.dispose();
      },
    );

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
      await Future<void>.delayed(Duration.zero);
      final activity = activityRepository.records.last;
      expect(activity.kind, McpActivityKind.security);
      expect(activity.outcome, McpActivityOutcome.denied);
      expect(activity.method, isNull);
      expect(activity.toolName, isNull);
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

class _MemoryActivityRepository implements McpActivityRepository {
  final records = <McpActivityRecord>[];

  @override
  Future<void> clearMcpActivityRecords() async {
    records.clear();
  }

  @override
  Future<List<McpActivityRecord>> loadMcpActivityRecords({
    int limit = 500,
  }) async {
    return records.reversed.take(limit).toList(growable: false);
  }

  @override
  Future<void> recordMcpActivity(McpActivityRecord record) async {
    records.add(record);
  }
}

class _FakeToolExecutor implements AiToolExecutor, AiToolApprovalTargetGuard {
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
      AiTool(
        name: 'client_set_plan_mode',
        description: 'Internal plan mode control.',
        properties: const {},
        executionMode: AiToolExecutionMode.planControl,
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
    if (name != 'run_command') return null;
    return const AiToolApprovalRequest(
      toolName: 'run_command',
      approvalType: 'remote_write',
      connectionId: 'server-1',
      connectionName: 'Test server',
      command: 'RUN uptime',
      reason: 'The command changes remote state.',
    );
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

  @override
  Future<bool> isApprovalTargetCurrent(AiToolApprovalRequest request) async {
    return true;
  }

  @override
  Future<String> executeApproved(
    AiToolApprovalRequest request,
    Map<String, dynamic> arguments,
  ) {
    return execute(request.toolName, arguments, approvedWrite: true);
  }
}

class _FakeExecutorWithoutGuard implements AiToolExecutor {
  @override
  Future<List<AiTool>> tools() async => [
    AiTool(
      name: 'run_command',
      description: 'Run a command.',
      properties: const {},
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (_) async => '{}',
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async =>
      (await tools()).map((tool) => tool.definition).toList();

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => const AiToolApprovalRequest(
    toolName: 'run_command',
    approvalType: 'remote_write',
    connectionId: 'server-1',
    connectionName: 'Test server',
    command: 'RUN uptime',
    reason: 'The command changes remote state.',
  );

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async => jsonEncode({'ok': true});

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) =>
      const AiCommandReview.readOnly();
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for MCP approval queue update.');
}
