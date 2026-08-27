// 不支持 SQLite 的平台上的遥测数据库连接占位实现。

import 'package:drift/drift.dart';

/// 当前平台不支持遥测数据库时明确抛出错误。
QueryExecutor openTelemetryDatabaseConnection() =>
    throw UnsupportedError('Cannot open telemetry database on this platform');

/// 当前平台不支持测试数据库时明确抛出错误。
QueryExecutor openTelemetryTestDatabaseConnection() => throw UnsupportedError(
  'Cannot open telemetry test database on this platform',
);
