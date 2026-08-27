// 未捕获异常遥测桥测试。
//
// 验证 FlutterError.onError 链式包装会以 app.diagnostic.log（category=crash）
// 写一条诊断遥测；dispose 后恢复原 handler；reportZoneError 与独立顶层函数
// 也会写同名事件。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/app_crash_telemetry_bridge.dart';
import 'package:ssh_mobile/services/telemetry/app_telemetry_contract.dart';

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

    test('installs a chained FlutterError onError and restores after dispose',
        () async {
      // 先把下一个（链尾）handler 装好，再安装桥。桥会记住链尾 handler，
      // 并在 dispose 后恢复它。
      final sink = <FlutterErrorDetails>[];
      FlutterError.onError = sink.add;

      bridge.install();
      expect(bridge.installed, isTrue);

      final reported =
          FlutterErrorDetails(exception: StateError('boom'), library: 'test');
      FlutterError.reportError(reported);
      await _settle();

      // 链式：桥先写遥测，再转发给链尾 handler。
      expect(sink, hasLength(1));
      final records = await harness.recordsByName();
      final diagnostics = records[AppTelemetryEvents.appDiagnosticLog.name];
      expect(diagnostics, hasLength(1));
      final record = diagnostics!.single;
      expect(record.properties, containsPair('category', 'crash'));
      expect(record.error?.errorCode,
          AppTelemetryErrorCodes.telemetryNetworkError.code);

      // dispose 恢复安装前的链尾 handler。
      await bridge.dispose();
      expect(bridge.installed, isFalse);
      expect(FlutterError.onError, sink.add);
    });

    test('reportZoneError writes a crash diagnostic', () async {
      await bridge.reportZoneError(
        StateError('zone failure'),
        StackTrace.current,
      );

      final diagnostics = (await harness.recordsByName())[
        AppTelemetryEvents.appDiagnosticLog.name
      ];
      expect(diagnostics, hasLength(1));
      expect(diagnostics!.single.properties, containsPair('category', 'crash'));
    });
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);