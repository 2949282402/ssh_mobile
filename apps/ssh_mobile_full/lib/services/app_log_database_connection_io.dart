// Native App 日志数据库连接实现。
//
// 正式环境使用后台 isolate 打开 SQLite，测试环境使用内存数据库，保证
// 日志初始化不会阻塞首帧且测试不会写入用户文件。

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log_database_constants.dart';

/// 打开正式环境的 App 日志数据库。
QueryExecutor openAppLogDatabaseConnection() {
  if (isFlutterTestEnvironment) {
    return NativeDatabase.memory();
  }

  return LazyDatabase(() async {
    final directory = await getApplicationSupportDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = File(p.join(directory.path, '$appLogDatabaseName.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

/// 打开内存测试数据库。
QueryExecutor openAppLogTestDatabaseConnection() => NativeDatabase.memory();

/// 判断当前进程是否由 Flutter 测试 runner 执行。
bool get isFlutterTestEnvironment {
  return Platform.environment['FLUTTER_TEST'] == 'true' ||
      Platform.script.path.endsWith('flutter_tester');
}
