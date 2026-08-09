// Web App 日志数据库连接实现。

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'app_log_database_constants.dart';

/// 使用 Drift Flutter 的 Web 持久化执行器。
QueryExecutor openAppLogDatabaseConnection() {
  return driftDatabase(name: appLogDatabaseName);
}

/// 使用独立名称的 Web 测试执行器，避免污染正式 IndexedDB 数据。
QueryExecutor openAppLogTestDatabaseConnection() {
  return driftDatabase(name: '${appLogDatabaseName}_test');
}
