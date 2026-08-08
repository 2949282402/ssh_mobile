// RAG Feature 的独立 Drift 数据库。
//
// rag.db 只归 RagModule 持有，Repository 不关闭数据库。正文和向量不入库，
// 以便数据库大小与文档缓存生命周期解耦。

import 'dart:convert';

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../domain/rag_models.dart';

part 'rag_database.g.dart';
part 'tables/rag_tables.dart';
part 'daos/rag_dao.dart';

/// Drift 在平台目录中创建的数据库基名。
const String ragDatabaseName = 'rag';

@DriftDatabase(
  tables: [RagDocuments, RagIndexMetadataTable, RagCacheEntries],
  daos: [RagDao],
)
final class RagDatabase extends _$RagDatabase implements Disposable {
  /// 打开生产 rag.db，或使用显式 Executor 供测试注入。
  factory RagDatabase({QueryExecutor? executor}) =>
      RagDatabase._(executor ?? driftDatabase(name: ragDatabaseName));

  RagDatabase._(super.executor);

  /// 创建内存数据库，避免测试写入平台目录。
  RagDatabase.forTesting(super.executor);

  bool _disposed = false;

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// 关闭数据库句柄；重复关闭安全。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await close();
  }
}
