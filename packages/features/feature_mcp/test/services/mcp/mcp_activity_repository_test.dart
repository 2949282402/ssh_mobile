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
}
