import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  test(
    'activity repository retains only the newest 500 safe records',
    () async {
      final database = McpDatabase.forTesting(NativeDatabase.memory());
      final repository = DriftMcpActivityRepository(database);
      addTearDown(database.dispose);

      final startedAt = DateTime.utc(2026, 7, 23);
      for (var index = 0; index < 501; index++) {
        await repository.recordMcpActivity(
          McpActivityRecord(
            occurredAt: startedAt.add(Duration(seconds: index)),
            kind: McpActivityKind.tool,
            method: 'tools/call',
            toolName: 'tool-$index',
            outcome: McpActivityOutcome.success,
            durationMs: index,
          ),
        );
      }

      final records = await repository.loadMcpActivityRecords();
      expect(records, hasLength(500));
      expect(records.first.toolName, 'tool-500');
      expect(records.last.toolName, 'tool-1');
      expect(records.first.policyReason, isNull);
      expect(records.first.durationMs, 500);

      await repository.clearMcpActivityRecords();
      expect(await repository.loadMcpActivityRecords(), isEmpty);
    },
  );

  test('activity persistence failures log no exception contents', () async {
    const secret = 'MCP_ACTIVITY_SECRET_20260824';
    final logger = _RecordingLogger();
    final recorder = McpActivityRecorder(
      _ThrowingActivityRepository(secret),
      logger: logger,
    );

    await recorder.record(
      kind: McpActivityKind.security,
      outcome: McpActivityOutcome.failed,
      policyReason: 'request_failed',
    );

    final logText = logger.entries.join('\n');
    expect(logText, contains('errorCode=activity_persistence_failed'));
    expect(logText, contains('errorType=StateError'));
    expect(logText, isNot(contains(secret)));
  });
}

class _ThrowingActivityRepository implements McpActivityRepository {
  const _ThrowingActivityRepository(this.secret);

  final String secret;

  @override
  Future<void> clearMcpActivityRecords() async {}

  @override
  Future<List<McpActivityRecord>> loadMcpActivityRecords({int limit = 500}) {
    return Future.value(const []);
  }

  @override
  Future<void> recordMcpActivity(McpActivityRecord record) {
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
