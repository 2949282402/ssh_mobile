import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/app_log_service.dart';
import '../utils/startup_instrumentation.dart';
import 'app_runtime_factory.dart';
import 'ssh_mobile_app.dart';

/// 应用启动边界，负责 Flutter 绑定、异常 Zone 和 Runtime 装配。
///
/// 业务 Service 不应回到这里自行创建；所有 App Scope 实例统一由
/// [AppRuntimeFactory] 创建，便于在退出时由 [AppRuntime] 反向释放。
final class AppBootstrap {
  AppBootstrap._();

  /// 启动应用并把未处理的异步异常桥接到应用日志。
  static Future<void> run() async {
    final appLogService = AppLogService();
    await runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        StartupInstrumentation.instance.recordMainStart();

        final runtime = await AppRuntimeFactory.create(
          appLogService: appLogService,
        );
        StartupInstrumentation.instance.recordRunAppStart();
        runApp(SshMobileApp(runtime: runtime));
      },
      (error, stackTrace) {
        appLogService.error(
          'Uncaught zone error',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }
}
