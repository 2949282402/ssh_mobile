import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart' as db;
import 'package:ssh_mobile/services/mcp/mcp_activity.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'activity repository retains only the newest 500 safe records',
    () async {
      final database = db.AppDatabase.forTesting();
      final storage = StorageService(database: database);
      addTearDown(() async {
        await storage.shutdown();
        storage.dispose();
        await database.close();
      });
      await storage.init();

      final startedAt = DateTime.utc(2026, 7, 23);
      for (var index = 0; index < 501; index++) {
        await storage.recordMcpActivity(
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

      final records = await storage.loadMcpActivityRecords();
      expect(records, hasLength(500));
      expect(records.first.toolName, 'tool-500');
      expect(records.last.toolName, 'tool-1');
      expect(records.first.policyReason, isNull);
      expect(records.first.durationMs, 500);

      await storage.clearMcpActivityRecords();
      expect(await storage.loadMcpActivityRecords(), isEmpty);
    },
  );
}
