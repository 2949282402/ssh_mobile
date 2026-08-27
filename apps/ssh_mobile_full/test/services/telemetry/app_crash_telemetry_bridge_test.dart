// 未捕获异常遥测桥测试。
//
// 验证 FlutterError.onError 链式包装会以 app.crash.reported（category=flutter）
// 写一条诊断遥测；dispose 后恢复原 handler；reportZoneError 与独立顶层函数
// 也会写同名事件。

import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/app_crash_telemetry_bridge.dart';

import 'telemetry_test_utils.dart';

void main() {
  group('AppCrashTelemetryBridge', () {
    late TelemetryTestHarness harness;
    late AppCrashTelemetryBridge bridge;

    setUp(() {
      harness = TelemetryTestHarness();
      bridge = AppCrashTelemetryBridge(telemetryClient: harness.client);
    });

    tearDown(() async {
      await bridge.dispose();
      await harness.dispose();
    });

    test(
      'installs a chained FlutterError onError and restores after dispose',
      () async {
        // 先把下一个（链尾）handler 装好，再安装桥。桥会记住链尾 handler，
        // 并在 dispose 后恢复它。
        final sink = <FlutterErrorDetails>[];
        FlutterError.onError = sink.add;

        bridge.install();
        expect(bridge.installed, isTrue);

        final reported = FlutterErrorDetails(
          exception: StateError('boom'),
          library: 'test',
        );
        FlutterError.reportError(reported);
        await _settle();

        // 链式：桥先写遥测，再转发给链尾 handler。
        expect(sink, hasLength(1));
        final records = await harness.recordsByName();
        final diagnostics = records[TelemetryEvents.appCrashReported.name];
        expect(diagnostics, hasLength(1));
        final record = diagnostics!.single;
        expect(record.properties, containsPair('category', 'flutter'));
        expect(record.error?.errorCode, TelemetryErrorCodes.appFatalError.code);

        // dispose 恢复安装前的链尾 handler。
        await bridge.dispose();
        expect(bridge.installed, isFalse);
        expect(FlutterError.onError, sink.add);
      },
    );

    test('reportZoneError writes a crash diagnostic', () async {
      await bridge.reportZoneError(
        StateError('zone failure'),
        StackTrace.current,
      );

      final diagnostics = (await harness
          .recordsByName())[TelemetryEvents.appErrorCaptured.name];
      expect(diagnostics, hasLength(1));
      expect(
        diagnostics!.single.properties,
        containsPair('category', 'uncaught'),
      );
    });

    test('chains and restores PlatformDispatcher.onError', () async {
      var previousCalls = 0;
      final previous = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        previousCalls++;
        return true;
      };

      addTearDown(() {
        PlatformDispatcher.instance.onError = previous;
      });

      bridge.install();
      final handled = PlatformDispatcher.instance.onError!(
        StateError('platform failure'),
        StackTrace.current,
      );
      await bridge.pendingReports;

      expect(handled, isTrue);
      expect(previousCalls, 1);
      final records = await harness.recordsByName();
      expect(records[TelemetryEvents.appCrashReported.name], hasLength(1));

      await bridge.dispose();
      expect(PlatformDispatcher.instance.onError, isNotNull);
      expect(
        PlatformDispatcher.instance.onError!(
          StateError('restored'),
          StackTrace.current,
        ),
        isTrue,
      );
      expect(previousCalls, 2);
    });

    test(
      'install and dispose are idempotent and do not clobber a replacement handler',
      () async {
        final previous = FlutterError.onError;
        bridge.install();
        final installed = FlutterError.onError;
        bridge.install();
        expect(FlutterError.onError, same(installed));

        FlutterError.onError = (details) {};
        await bridge.dispose();
        expect(FlutterError.onError, isNot(same(previous)));
        await bridge.dispose();
      },
    );
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);
