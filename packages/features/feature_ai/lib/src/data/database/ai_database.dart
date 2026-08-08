// AI Feature 的独立 Drift 数据库。
//
// 聊天、Agent 运行指标和 trace 由 AiModule 共同持有在 ai.db 中，AppDatabase
// 不再声明这些表。生产数据库异常必须向上抛出，禁止静默退回内存实现。

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'ai_database.g.dart';
part 'tables/ai_chat_tables.dart';
part 'tables/agent_metrics_tables.dart';
part 'tables/agent_trace_tables.dart';
part 'daos/ai_chat_dao.dart';
part 'daos/agent_metrics_dao.dart';
part 'daos/agent_trace_dao.dart';

/// Drift 在平台目录中创建的数据库基名。
const String aiDatabaseName = 'ai';

/// AI Module 的独立数据库 Owner。
@DriftDatabase(
  tables: [
    AiChats,
    AiChatMessages,
    AgentRunMetricsTable,
    AgentTraceEventsTable,
  ],
  daos: [AiChatDao, AgentMetricsDao, AgentTraceDao],
)
final class AiDatabase extends _$AiDatabase implements Disposable {
  /// 创建生产 ai.db；关闭责任由 [AiModule] 承担。
  AiDatabase() : super(driftDatabase(name: aiDatabaseName));

  /// 使用测试执行器，避免单元测试访问平台数据库目录。
  AiDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  bool _disposed = false;

  /// 关闭数据库句柄；重复调用安全。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await close();
  }
}
