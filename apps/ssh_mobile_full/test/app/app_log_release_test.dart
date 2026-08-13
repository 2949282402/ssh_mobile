import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_log_database.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

/// 转发到内部 [drift.QueryExecutor] 的替身，仅记录 `close()` 调用次数，
/// 用于确定性地断言日志数据库是否被关闭。
final class _RecordingQueryExecutor implements drift.QueryExecutor {
  _RecordingQueryExecutor(this._inner);

  final drift.QueryExecutor _inner;
  int closeCalls = 0;

  @override
  drift.SqlDialect get dialect => _inner.dialect;

  @override
  Future<bool> ensureOpen(drift.QueryExecutorUser user) =>
      _inner.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) => _inner.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _inner.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _inner.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _inner.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _inner.runCustom(statement, args);

  @override
  Future<void> runBatched(drift.BatchedStatements statements) =>
      _inner.runBatched(statements);

  @override
  drift.TransactionExecutor beginTransaction() => _inner.beginTransaction();

  @override
  drift.QueryExecutor beginExclusive() => _inner.beginExclusive();

  @override
  Future<void> close() async {
    closeCalls++;
    await _inner.close();
  }
}

/// 建立 AppLogService 与 AppLogDatabase 的真实释放行为：
/// - AppLogService.dispose 只取消 UI 通知 Timer，不会关闭已绑定的日志数据库。
/// - AppLogDatabase 由其 Owner（binder）显式 dispose 关闭，且幂等。
///
/// 该用例独立于 app_runtime_test.dart（独立 isolate），因此可以安全地
/// dispose 全局单例 AppLogService。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppLogService.dispose does not close the bound log database; '
      'the database owner closes it', () async {
    final logs = AppLogService.instance;
    logs.clear();
    logs.resetDatabaseForTesting();

    final recording = _RecordingQueryExecutor(NativeDatabase.memory());
    final db = AppLogDatabase.forTesting(recording);
    try {
      await logs.setDatabase(db);
      await logs.pendingDbWrites;
      expect(logs.databaseOpen, isTrue);
      expect(recording.closeCalls, 0);

      // 审计结论：dispose 只取消通知 Timer，不关闭数据库。
      logs.dispose();
      expect(logs.activeTimerCount, 0);
      expect(
        recording.closeCalls,
        0,
        reason: 'AppLogService.dispose must not close the bound log DB',
      );

      // 数据库由其 Owner 显式释放，dispose 关闭 Drift handle 且幂等。
      await db.dispose();
      expect(recording.closeCalls, 1);
      await db.dispose();
      expect(recording.closeCalls, 1);
    } finally {
      if (recording.closeCalls == 0) {
        await db.dispose();
      }
      logs.resetDatabaseForTesting();
    }
  });
}
