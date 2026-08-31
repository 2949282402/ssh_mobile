// Web 遥测数据库连接实现。

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'telemetry_database_constants.dart';

/// 使用 Drift Flutter 的 Web 持久化执行器。
QueryExecutor openTelemetryDatabaseConnection() {
  return driftDatabase(name: telemetryDatabaseName);
}
