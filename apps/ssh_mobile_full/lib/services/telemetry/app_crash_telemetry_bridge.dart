// 未捕获异常与应用错误遥测桥。
//
// 任务要求把 FlutterError.onError / PlatformDispatcher.instance.onError /
// AppLogService 错误 sink 桥接到 app.crash.reported / app.error.captured。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';

import '../../app/app_runtime.dart';

/// 安装未捕获错误遥测入口。
///
/// [install] 幂等；链式包装 [AppLogService.install] 已经安装的 FlutterError /
/// PlatformDispatcher 钩子，在本地日志之外追加一条诊断遥测记录。AppRuntime
/// 创建前不会安装（遥测客户端尚不存在），避免在启动早期产生无宿主事件。
final class AppCrashTelemetryBridge {
  AppCrashTelemetryBridge({required this.telemetryClient});

  final TelemetryClient telemetryClient;
  FlutterExceptionHandler? _previousFlutterError;
  bool _installed = false;

  /// 是否已安装 FlutterError 链式入口；供测试与 AppRuntime 健康检查读取。
  bool get installed => _installed;

  /// 安装错误/崩溃遥测入口。
  void install() {
    if (_installed) return;
    _installed = true;

    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(_reportFlutterError(details));
      _previousFlutterError?.call(details);
    };
  }

  Future<void> _reportFlutterError(FlutterErrorDetails details) async {
    await telemetryClient.record(
      event: TelemetryEvents.appCrashReported,
      properties: {'message': details.exceptionAsString(), 'category': 'crash'},
      stackTrace: details.stack?.toString(),
      errorCode: TelemetryErrorCodes.appFatalError,
      errorMessage: details.exceptionAsString(),
    );
  }

  /// 供 AppBootstrap 的 runZonedGuarded 兜底路径调用（找不到 runtime 时）。
  Future<void> reportZoneError(Object error, StackTrace stackTrace) async {
    await telemetryClient.record(
      event: TelemetryEvents.appErrorCaptured,
      properties: {
        'message': 'Uncaught zone error: $error',
        'category': 'uncaught',
      },
      stackTrace: stackTrace.toString(),
      errorCode: TelemetryErrorCodes.appUncaughtError,
      errorMessage: 'Uncaught zone error: $error',
    );
  }

  Future<void> dispose() async {
    if (!_installed) return;
    _installed = false;
    final previous = _previousFlutterError;
    if (previous != null) {
      FlutterError.onError = previous;
      _previousFlutterError = null;
    }
  }
}

/// AppBootstrap 把未捕获 zone 错误路由到 AppRuntime 持有的遥测桥。
Future<void> reportUncaughtErrorToRuntime(
  AppRuntime runtime, {
  required Object error,
  required StackTrace stackTrace,
}) async {
  await runtime.telemetryClient?.record(
    event: TelemetryEvents.appErrorCaptured,
    properties: {
      'message': 'Uncaught zone error: $error',
      'category': 'uncaught',
    },
    stackTrace: stackTrace.toString(),
    errorCode: TelemetryErrorCodes.appUncaughtError,
    errorMessage: 'Uncaught zone error: $error',
  );
}
