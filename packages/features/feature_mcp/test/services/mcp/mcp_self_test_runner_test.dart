// MCP 协议自检 Runner 的独立状态机测试。

import 'dart:collection';
import 'dart:io';

import 'package:feature_mcp/feature_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _RecordingActivityRepository repository;

  setUp(() {
    repository = _RecordingActivityRepository();
  });

  test('stopped server fails before loading a token', () async {
    var tokenLoads = 0;
    final result = await _runner(repository, const []).run(
      serverRunning: false,
      url: Uri.parse('http://127.0.0.1:8765/mcp'),
      loadToken: () async {
        tokenLoads++;
        return 'token';
      },
    );

    expect(result.succeeded, isFalse);
    expect(result.failureCode, 'server_not_running');
    expect(tokenLoads, 0);
    await _flushActivity();
    expect(repository.records.single.policyReason, 'server_not_running');
  });

  test('initialize transport failures retain stable failure codes', () async {
    final cases = <(McpSelfTestResponse, String)>[
      (
        const McpSelfTestResponse(
          reachable: false,
          statusCode: null,
          succeeded: false,
        ),
        'connection_failed',
      ),
      (
        const McpSelfTestResponse(
          reachable: true,
          statusCode: HttpStatus.unauthorized,
          succeeded: false,
        ),
        'authentication_failed',
      ),
      (
        const McpSelfTestResponse(
          reachable: true,
          statusCode: HttpStatus.forbidden,
          succeeded: false,
        ),
        'authentication_failed',
      ),
      (
        const McpSelfTestResponse(
          reachable: true,
          statusCode: HttpStatus.ok,
          succeeded: false,
        ),
        'initialize_failed',
      ),
    ];

    for (final (response, code) in cases) {
      repository.records.clear();
      final transport = _QueueTransport([response]);
      final result =
          await McpSelfTestRunner(
            transport: transport,
            activityRecorder: McpActivityRecorder(repository),
          ).run(
            serverRunning: true,
            url: Uri.parse('http://127.0.0.1:8765/mcp'),
            loadToken: () async => 'token',
          );

      expect(result.failureCode, code);
      expect(result.toolsListed, isFalse);
      expect(transport.methods, <String>['initialize']);
      await _flushActivity();
      expect(repository.records.single.policyReason, code);
    }
  });

  test('tools/list failure preserves initialized state', () async {
    final result =
        await _runner(repository, const [
          McpSelfTestResponse(
            reachable: true,
            statusCode: HttpStatus.ok,
            succeeded: true,
          ),
          McpSelfTestResponse(
            reachable: false,
            statusCode: null,
            succeeded: false,
          ),
        ]).run(
          serverRunning: true,
          url: Uri.parse('http://127.0.0.1:8765/mcp'),
          loadToken: () async => 'token',
        );

    expect(result.initialized, isTrue);
    expect(result.serverReachable, isFalse);
    expect(result.failureCode, 'tools_list_failed');
  });

  test(
    'successful self-test sends initialize then tools/list and records success',
    () async {
      final transport = _QueueTransport(const [
        McpSelfTestResponse(
          reachable: true,
          statusCode: HttpStatus.ok,
          succeeded: true,
        ),
        McpSelfTestResponse(
          reachable: true,
          statusCode: HttpStatus.ok,
          succeeded: true,
        ),
      ]);
      final runner = McpSelfTestRunner(
        transport: transport,
        activityRecorder: McpActivityRecorder(repository),
      );

      final result = await runner.run(
        serverRunning: true,
        url: Uri.parse('http://127.0.0.1:8765/mcp'),
        loadToken: () async => 'token',
      );

      expect(result.succeeded, isTrue);
      expect(result.failureCode, isNull);
      expect(transport.methods, <String>['initialize', 'tools/list']);
      await _flushActivity();
      expect(repository.records.single.outcome, McpActivityOutcome.success);
    },
  );
}

McpSelfTestRunner _runner(
  McpActivityRepository repository,
  List<McpSelfTestResponse> responses,
) => McpSelfTestRunner(
  transport: _QueueTransport(responses),
  activityRecorder: McpActivityRecorder(repository),
);

Future<void> _flushActivity() => Future<void>.delayed(Duration.zero);

final class _QueueTransport implements McpSelfTestTransport {
  _QueueTransport(Iterable<McpSelfTestResponse> responses)
    : _responses = Queue<McpSelfTestResponse>.of(responses);

  final Queue<McpSelfTestResponse> _responses;
  final List<String> methods = <String>[];

  @override
  Future<McpSelfTestResponse> postJson({
    required Uri url,
    required String token,
    required Map<String, dynamic> body,
  }) async {
    expect(url.host, '127.0.0.1');
    expect(token, 'token');
    methods.add(body['method']! as String);
    return _responses.removeFirst();
  }
}

final class _RecordingActivityRepository implements McpActivityRepository {
  final List<McpActivityRecord> records = <McpActivityRecord>[];

  @override
  Future<void> clearMcpActivityRecords() async => records.clear();

  @override
  Future<List<McpActivityRecord>> loadMcpActivityRecords({
    int limit = 500,
  }) async => records.take(limit).toList(growable: false);

  @override
  Future<void> recordMcpActivity(McpActivityRecord record) async {
    records.add(record);
  }
}
