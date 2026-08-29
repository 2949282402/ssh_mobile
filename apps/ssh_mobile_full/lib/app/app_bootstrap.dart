import 'dart:async';

import 'package:flutter/widgets.dart';

import '../utils/startup_instrumentation.dart';
import '../services/telemetry/app_crash_telemetry_bridge.dart';
import 'app_runtime.dart';
import 'app_runtime_factory.dart';
import 'ssh_mobile_app.dart';

/// 应用启动边界，负责 Flutter 绑定、异常 Zone 和 Runtime 装配。
///
/// 业务 Service 不应回到这里自行创建；所有 App Scope 实例统一由
/// [AppRuntimeFactory] 创建，便于在退出时由 [AppRuntime] 反向释放。
final class AppBootstrap {
  AppBootstrap._();

  /// 启动应用并把未处理的异步异常桥接到应用日志。
  ///
  /// [runtimeFactory] and [startApp] are injectable so startup failure handling
  /// can be exercised without constructing the complete App Scope graph.
  static Future<void> run({
    Future<AppRuntime> Function()? runtimeFactory,
    void Function(Widget app)? startApp,
  }) async {
    AppRuntime? runtime;
    await runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        StartupInstrumentation.instance.recordMainStart();

        runtime = await (runtimeFactory ?? AppRuntimeFactory.create)();
        StartupInstrumentation.instance.recordRunAppStart();
        (startApp ?? runApp)(SshMobileApp(runtime: runtime));
      },
      (error, stackTrace) {
        final currentRuntime = runtime;
        if (currentRuntime != null && !currentRuntime.isDisposed) {
          // Keep the existing local App Scope log projection while the
          // structured bridge writes the durable telemetry record below.
          currentRuntime.appLogService.error(
            'Uncaught zone error',
            error: error,
            stackTrace: stackTrace,
          );
          // The bridge awaits durable local insertion before attempting its
          // asynchronous upload. runZonedGuarded itself remains non-blocking.
          unawaited(
            reportUncaughtErrorToRuntime(
              currentRuntime,
              error: error,
              stackTrace: stackTrace,
            ),
          );
        } else {
          // Runtime 尚未创建或已经释放时无法注入 Logger，只保留不含错误、
          // 主机、路径或堆栈内容的启动边界兜底，避免泄漏敏感信息。
          debugPrint('Uncaught zone error before AppRuntime logging');
        }
      },
    );
  }
}
