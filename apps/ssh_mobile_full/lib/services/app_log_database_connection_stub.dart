// 不支持 SQLite 的平台上的 App 日志数据库连接占位实现。

import 'package:drift/drift.dart';

/// 当前平台不支持 App 日志数据库时明确抛出错误。
QueryExecutor openAppLogDatabaseConnection() =>
    throw UnsupportedError('Cannot open App log database on this platform');

/// 当前平台不支持测试数据库时明确抛出错误。
QueryExecutor openAppLogTestDatabaseConnection() => throw UnsupportedError(
  'Cannot open App log test database on this platform',
);
