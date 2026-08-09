// Terminal-only App 的启动边界。
//
// 启动阶段只装配最小 Runtime；任何未选择 Feature 都不在这里注册，避免
// 通过复制 Full App 的入口而把 AI、SFTP 或其他平台 SDK 带入编译图。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter/widgets.dart';

import 'terminal_app.dart';
import 'terminal_app_runtime.dart';

/// Terminal-only App 启动协调器。
final class TerminalAppBootstrap {
  TerminalAppBootstrap._();

  /// 初始化 Flutter 并启动最小 App Shell。
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    TerminalAppRuntime? runtime;
    await runZonedGuarded(
      () async {
        runtime = await TerminalAppRuntime.create();
        runApp(TerminalOnlyApp(runtime: runtime!));
      },
      (error, stackTrace) {
        runtime?.logger.log(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.error,
            source: 'terminal_app',
            message: 'Unhandled Terminal-only App error',
            error: error,
            stackTrace: stackTrace,
          ),
        );
      },
    );
  }
}
