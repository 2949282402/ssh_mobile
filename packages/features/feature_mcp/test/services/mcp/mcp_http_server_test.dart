import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  group('McpHttpServer', () {
    late McpHttpRequestHandler handler;
    late _MemoryActivityRepository activityRepository;

    setUp(() async {
      activityRepository = _MemoryActivityRepository();
      final activityRecorder = McpActivityRecorder(activityRepository);
      final executor = _FakeToolExecutor();
      handler = McpHttpRequestHandler(
        port: 38321,
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

    Future<_JsonResponse> postJson(Map<String, dynamic> body) async {
      final response = await handler.handle(
        McpHttpRequestData(
          path: '/mcp',
          method: 'POST',
          contentType: ContentType.json,
          authorization: 'Bearer secret',
          origin: null,
          body: Future.value(jsonEncode(body)),
        ),
      );
      final rawBody = response.body ?? '';
      return _JsonResponse(
        statusCode: response.statusCode,
        rawBody: rawBody,
        body: rawBody.isEmpty ? const {} : jsonDecode(rawBody) as Map,
      );
    }

    McpHttpRequestData requestData({
      required String path,
      required String method,
      String authorization = 'Bearer secret',
      Map<String, dynamic> body = const {},
    }) {
      return McpHttpRequestData(
        path: path,
        method: method,
        contentType: ContentType.json,
        authorization: authorization,
        origin: null,
        body: Future.value(jsonEncode(body)),
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

    test('tool execution errors do not expose secrets', () async {
      const secret = 'MCP_EXCEPTION_SECRET_20260824';
      final logger = _RecordingLogger();
      final toolHandler = McpToolHandler(
        aiToolService: _ThrowingToolExecutor(secret),
        settingsProvider: () => const McpServerSettings(token: 'secret'),
        logger: logger,
      );

      final response = await toolHandler.handle(
        const McpJsonRpcRequest(
          id: 'error-redaction-test',
          hasId: true,
          method: 'tools/call',
          params: {'name': 'list_servers', 'arguments': <String, dynamic>{}},
        ),
      );

      final result = response.result! as Map;
      final text = result['content'][0]['text'] as String;
      expect(result['isError'], isTrue);
      expect(text, contains('tool_execution_failed'));
      expect(text, isNot(contains(secret)));
      expect(logger.entries.join('\n'), isNot(contains(secret)));
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

    test('approval timeout keeps a distinct activity reason', () async {
      final queue = McpApprovalQueue(
        pendingTimeout: const Duration(milliseconds: 10),
      );
      final activityRepository = _MemoryActivityRepository();
      final executor = _FakeToolExecutor();
      final handler = McpToolHandler(
        aiToolService: executor,
        settingsProvider: () => const McpServerSettings(token: 'secret'),
        activityRecorder: McpActivityRecorder(activityRepository),
        approvalQueue: queue,
      );

      final response = await handler.handle(
        const McpJsonRpcRequest(
          id: 'timeout-test',
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
      await Future<void>.delayed(Duration.zero);
      expect(
        activityRepository.records.last.policyReason,
        'secondary_approval_timeout',
      );
      queue.dispose();
    });

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
      'review mode denies a state-changing tool outside the review set',
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
        expect(result['isError'], isTrue);
        expect(queue.pending, isEmpty);
        expect(executor.executedTools, isNot(contains('run_command')));
        queue.dispose();
      },
    );

    test(
      'review mode executes a read-only tool outside the review set',
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
            id: 'unconfigured-readonly-test',
            hasId: true,
            method: 'tools/call',
            params: {'name': 'list_servers', 'arguments': <String, dynamic>{}},
          ),
        );

        final result = response.result! as Map;
        expect(result['isError'], isFalse);
        expect(queue.pending, isEmpty);
        expect(executor.executedTools, contains('list_servers'));
        queue.dispose();
      },
    );

    test(
      'review mode uses the approval guard for an unqueued dynamic request',
      () async {
        final queue = McpApprovalQueue();
        final executor = _FakeReadApprovalExecutor();
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
            id: 'dynamic-read-test',
            hasId: true,
            method: 'tools/call',
            params: {
              'name': 'sftp_read_text',
              'arguments': <String, dynamic>{'path': '/tmp/demo.txt'},
            },
          ),
        );

        final result = response.result! as Map;
        expect(result['isError'], isFalse);
        expect(executor.approvedExecutions, 1);
        expect(executor.unapprovedExecutions, 0);
        expect(queue.pending, isEmpty);
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
      final response = await handler.handle(
        requestData(path: '/mcp', method: 'GET'),
      );

      expect(response.statusCode, 405);
      expect(response.headers[HttpHeaders.allowHeader], 'POST');
    });

    test('wrong path returns 404', () async {
      final response = await handler.handle(
        requestData(path: '/wrong', method: 'GET'),
      );

      expect(response.statusCode, 404);
    });

    test('invalid token returns 401', () async {
      final response = await handler.handle(
        requestData(
          path: '/mcp',
          method: 'POST',
          authorization: 'Bearer wrong',
          body: {'jsonrpc': '2.0', 'id': 5, 'method': 'ping'},
        ),
      );

      expect(response.statusCode, 401);
      await Future<void>.delayed(Duration.zero);
      final activity = activityRepository.records.last;
      expect(activity.kind, McpActivityKind.security);
      expect(activity.outcome, McpActivityOutcome.denied);
      expect(activity.method, isNull);
      expect(activity.toolName, isNull);
    });

    test('request failures log only a stable code and error type', () async {
      const secret = 'MCP_HTTP_SECRET_20260824';
      final logger = _RecordingLogger();
      final guardedHandler = McpHttpRequestHandler(
        port: 38321,
        token: 'secret',
        router: McpJsonRpcRouter(
          lifecycleHandler: const McpLifecycleHandler(),
          toolHandler: McpToolHandler(
            aiToolService: _FakeToolExecutor(),
            settingsProvider: () => const McpServerSettings(token: 'secret'),
          ),
        ),
        logger: logger,
      );

      final response = await guardedHandler.handle(
        McpHttpRequestData(
          path: '/mcp',
          method: 'POST',
          contentType: ContentType.json,
          authorization: 'Bearer secret',
          origin: null,
          body: Future<String>.error(
            StateError('Authorization: Bearer $secret'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.internalServerError);
      final logText = logger.entries.join('\n');
      expect(logText, contains('errorCode=request_failed'));
      expect(logText, contains('errorType=StateError'));
      expect(logText, isNot(contains(secret)));
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

class _FakeToolExecutor implements McpToolExecutor, McpApprovalTargetGuard {
  var executedTools = <String>[];

  @override
  Future<List<McpTool>> tools() async {
    return [
      const McpTool(
        name: 'list_servers',
        description: 'List saved servers.',
        properties: {},
      ),
      const McpTool(
        name: 'run_command',
        description: 'Run a command.',
        properties: {
          'connectionId': {'type': 'string'},
          'command': {'type': 'string'},
        },
        required: ['connectionId', 'command'],
        executionMode: McpToolExecutionMode.stateChanging,
      ),
      const McpTool(
        name: 'client_set_plan_mode',
        description: 'Internal plan mode control.',
        properties: {},
        executionMode: McpToolExecutionMode.planControl,
      ),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    const adapter = McpAiToolAdapter();
    return (await tools()).map(adapter.toMcpTool).toList();
  }

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (name != 'run_command') return null;
    return const McpApprovalRequest(
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
  Future<bool> isApprovalTargetCurrent(McpApprovalRequest request) async {
    return true;
  }

  @override
  Future<String> executeApproved(
    McpApprovalRequest request,
    Map<String, dynamic> arguments,
  ) {
    return execute(request.toolName, arguments, approvedWrite: true);
  }
}

class _ThrowingToolExecutor implements McpToolExecutor {
  _ThrowingToolExecutor(this.secret);

  final String secret;

  @override
  Future<List<McpTool>> tools() async => const [
    McpTool(
      name: 'list_servers',
      description: 'List saved servers.',
      properties: {},
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    const adapter = McpAiToolAdapter();
    return (await tools()).map(adapter.toMcpTool).toList();
  }

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => null;

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) {
    throw StateError('Authorization: Bearer $secret');
  }
}

class _RecordingLogger implements McpLoggerPort {
  final entries = <String>[];

  @override
  void info(String message, {String? details}) {
    entries.add('$message|$details');
  }

  @override
  void warning(String message, {String? details}) {
    entries.add('$message|$details');
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    entries.add('$message|$error|$stackTrace|$details');
  }
}

class _FakeExecutorWithoutGuard implements McpToolExecutor {
  @override
  Future<List<McpTool>> tools() async => [
    const McpTool(
      name: 'run_command',
      description: 'Run a command.',
      properties: {},
      executionMode: McpToolExecutionMode.stateChanging,
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    const adapter = McpAiToolAdapter();
    return (await tools()).map(adapter.toMcpTool).toList();
  }

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => const McpApprovalRequest(
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
}

class _FakeReadApprovalExecutor
    implements McpToolExecutor, McpApprovalTargetGuard {
  int approvedExecutions = 0;
  int unapprovedExecutions = 0;

  @override
  Future<List<McpTool>> tools() async => [
    const McpTool(
      name: 'sftp_read_text',
      description: 'Read a remote text file.',
      properties: {},
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    const adapter = McpAiToolAdapter();
    return (await tools()).map(adapter.toMcpTool).toList();
  }

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => const McpApprovalRequest(
    toolName: 'sftp_read_text',
    approvalType: 'remote_read',
    connectionId: 'client',
    connectionName: 'SSH Mobile client',
    command: 'SFTP READ /tmp/demo.txt',
    reason: 'Remote file reads require user approval.',
  );

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    unapprovedExecutions += 1;
    return jsonEncode({'ok': true});
  }

  @override
  Future<bool> isApprovalTargetCurrent(McpApprovalRequest request) async =>
      true;

  @override
  Future<String> executeApproved(
    McpApprovalRequest request,
    Map<String, dynamic> arguments,
  ) async {
    approvedExecutions += 1;
    return jsonEncode({'ok': true});
  }
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for MCP approval queue update.');
}
