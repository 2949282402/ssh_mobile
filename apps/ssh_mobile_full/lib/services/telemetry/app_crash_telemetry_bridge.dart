// 未捕获异常与应用错误遥测桥。
//
// The bridge owns only the process-global error-handler wrappers. The
// TelemetryClient and its SQLite storage remain AppRuntime-owned resources.

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';

import '../../app/app_runtime.dart';

/// Installs chained, durable crash/error telemetry handlers.
///
/// Each handler schedules a record operation whose first await is the local
/// [TelemetryStorage.insertRecord] performed by [TelemetryClient.record]. The
/// operation then flushes asynchronously. Existing handlers are always called
/// and are restored only when the bridge still owns the installed wrapper, so
/// another component cannot be silently clobbered during disposal.
final class AppCrashTelemetryBridge {
  AppCrashTelemetryBridge({required this.telemetryClient});

  final TelemetryClient telemetryClient;
  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousPlatformError;
  FlutterExceptionHandler? _installedFlutterError;
  bool Function(Object, StackTrace)? _installedPlatformError;
  Future<void> _reportQueue = Future<void>.value();
  bool _installed = false;
  bool _disposed = false;

  /// Whether the bridge currently owns both global wrappers.
  bool get installed => _installed;

  /// Completes after every report accepted by a handler has been durably
  /// recorded and its asynchronous flush attempt has settled.
  Future<void> get pendingReports => _reportQueue;

  /// Installs Flutter and platform error handlers exactly once.
  void install() {
    if (_installed || _disposed) return;
    _previousFlutterError = FlutterError.onError;
    _previousPlatformError = PlatformDispatcher.instance.onError;

    // ignore: prefer_function_declarations_over_variables
    final flutterHandler = (FlutterErrorDetails details) {
      _enqueueReport(() => _reportFlutterError(details));
      _previousFlutterError?.call(details);
    };
    // ignore: prefer_function_declarations_over_variables
    final platformHandler = (Object error, StackTrace stackTrace) {
      _enqueueReport(() => _reportPlatformError(error, stackTrace));
      return _previousPlatformError?.call(error, stackTrace) ?? false;
    };

    _installedFlutterError = flutterHandler;
    _installedPlatformError = platformHandler;
    FlutterError.onError = flutterHandler;
    PlatformDispatcher.instance.onError = platformHandler;
    _installed = true;
  }

  Future<void> _reportFlutterError(FlutterErrorDetails details) async {
    await _recordAndFlush(
      event: TelemetryEvents.appCrashReported,
      category: 'flutter',
      errorCode: TelemetryErrorCodes.appFatalError,
      errorMessage: details.exceptionAsString(),
      stackTrace: details.stack?.toString(),
    );
  }

  Future<void> _reportPlatformError(Object error, StackTrace stackTrace) {
    return _recordAndFlush(
      event: TelemetryEvents.appCrashReported,
      category: 'platform',
      errorCode: TelemetryErrorCodes.appFatalError,
      errorMessage: error.toString(),
      stackTrace: stackTrace.toString(),
    );
  }

  /// Reports a runZonedGuarded error as non-fatal uncaught application error.
  Future<void> reportZoneError(Object error, StackTrace stackTrace) {
    return _enqueueReport(
      () => _recordAndFlush(
        event: TelemetryEvents.appErrorCaptured,
        category: 'uncaught',
        errorCode: TelemetryErrorCodes.appUncaughtError,
        errorMessage: error.toString(),
        stackTrace: stackTrace.toString(),
      ),
    );
  }

  Future<void> _recordAndFlush({
    required TelemetryEventDefinition event,
    required String category,
    required TelemetryErrorCodeDefinition errorCode,
    required String? errorMessage,
    required String? stackTrace,
  }) async {
    // The event message is intentionally a static classifier. Raw exception
    // text is retained only in the client's centralized redaction boundary.
    final accepted = await telemetryClient.record(
      event: event,
      properties: <String, dynamic>{
        'message': event == TelemetryEvents.appCrashReported
            ? 'Application crash captured'
            : 'Application error captured',
        'category': category,
      },
      errorCode: errorCode,
      errorMessage: errorMessage,
      stackTrace: stackTrace,
    );
    if (accepted) await telemetryClient.flush();
  }

  Future<void> _enqueueReport(Future<void> Function() report) {
    final previous = _reportQueue;
    _reportQueue = previous.then<void>((_) async {
      try {
        await report();
      } on Object {
        // A crash reporter must never throw back into Flutter's handler or
        // recursively create a telemetry-network diagnostic.
      }
    });
    return _reportQueue;
  }

  /// Restores only wrappers still owned by this bridge and drains reports
  /// before the AppRuntime closes the client's local SQLite store.
  Future<void> dispose() async {
    if (!_disposed) {
      _disposed = true;
      if (identical(FlutterError.onError, _installedFlutterError)) {
        FlutterError.onError = _previousFlutterError;
      }
      if (identical(
        PlatformDispatcher.instance.onError,
        _installedPlatformError,
      )) {
        PlatformDispatcher.instance.onError = _previousPlatformError;
      }
      _installed = false;
      _installedFlutterError = null;
      _installedPlatformError = null;
      _previousFlutterError = null;
      _previousPlatformError = null;
    }
    await _reportQueue;
  }
}

/// AppBootstrap routes runZonedGuarded errors to the Runtime-owned bridge.
Future<void> reportUncaughtErrorToRuntime(
  AppRuntime runtime, {
  required Object error,
  required StackTrace stackTrace,
}) async {
  final bridge = runtime.crashTelemetryBridge;
  if (bridge != null) {
    await bridge.reportZoneError(error, stackTrace);
    return;
  }
  final client = runtime.telemetryClient;
  if (client == null) return;
  try {
    final accepted = await client.record(
      event: TelemetryEvents.appErrorCaptured,
      properties: const {
        'message': 'Application error captured',
        'category': 'uncaught',
      },
      errorCode: TelemetryErrorCodes.appUncaughtError,
      errorMessage: error.toString(),
      stackTrace: stackTrace.toString(),
    );
    if (accepted) await client.flush();
  } on Object {
    // The fallback is used only by synthetic runtimes without a bridge. A
    // telemetry storage/network failure must not re-enter runZonedGuarded.
  }
}
