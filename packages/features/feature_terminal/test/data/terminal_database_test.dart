import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_terminal/feature_terminal.dart';

void main() {
  late TerminalDatabase database;

  setUp(() {
    database = TerminalDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.dispose());

  test(
    'Terminal history repository keeps the newest 200 metadata records',
    () async {
      final repository = DriftTerminalHistoryRepository(database);
      final base = DateTime.utc(2026, 1, 1);

      for (var index = 0; index < 201; index++) {
        final time = base.add(Duration(minutes: index));
        await repository.saveRecord(
          TerminalHistoryRecord(
            sessionId: 'session-$index',
            connectionId: 'connection',
            connectionName: 'Test server',
            displayName: 'Terminal $index',
            tmuxSessionName: null,
            state: 'connected',
            errorMessage: null,
            createdAt: time,
            updatedAt: time,
          ),
        );
      }

      final records = await repository.loadRecords();
      expect(records, hasLength(200));
      expect(records.first.sessionId, 'session-200');
      expect(records.last.sessionId, 'session-1');

      await repository.removeRecord('session-200');
      expect(
        (await repository.loadRecords()).any(
          (record) => record.sessionId == 'session-200',
        ),
        isFalse,
      );
    },
  );
}
