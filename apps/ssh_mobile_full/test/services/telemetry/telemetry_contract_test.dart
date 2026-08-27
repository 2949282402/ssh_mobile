// AppScope 遥测常量镜像与 TelemetryCatalog 的一致性测试。
//
// app_telemetry_contract.dart 是 contract 生成目录的 App Scope 镜像；本测试
// 通过 TelemetryCatalog 的公开校验面验证镜像并未漂移：
// - 每个 AppTelemetryEvents 事件都能用其 name/version/properties 构造一条
//   合法记录并通过 isValidRecord；
// - 每个 AppTelemetryErrorCodes 错误码都通过 isValidErrorCode。

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/app_telemetry_contract.dart';

void main() {
  group('AppTelemetryEvents mirror synchronisation', () {
    test('every mirrored event passes catalog validation', () {
      const events = <TelemetryEventDefinition>[
        AppTelemetryEvents.appLifecycleStarted,
        AppTelemetryEvents.appLifecycleBackgrounded,
        AppTelemetryEvents.appLifecycleForegrounded,
        AppTelemetryEvents.networkQuicConnected,
        AppTelemetryEvents.networkQuicFailed,
        AppTelemetryEvents.networkRelayConnected,
        AppTelemetryEvents.networkRelayFallback,
        AppTelemetryEvents.sshSessionStarted,
        AppTelemetryEvents.sshSessionTerminated,
        AppTelemetryEvents.sshSessionFailed,
        AppTelemetryEvents.sftpTransferStarted,
        AppTelemetryEvents.sftpTransferCompleted,
        AppTelemetryEvents.sftpTransferFailed,
        AppTelemetryEvents.appDiagnosticLog,
      ];

      for (final def in events) {
        final record = TelemetryEventRecord(
          eventId: 'probe',
          recordType: def.recordType,
          eventName: def.name,
          eventVersion: def.version,
          deviceId: 'dev',
          sessionId: 'sess',
          traceId: 'trace',
          occurredAt: DateTime.now().toUtc(),
          feature: def.feature,
          severity: def.severity,
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'linux',
          properties: {
            for (final key in def.allowedProperties) key: _sampleValue(key),
          },
        );
        expect(
          TelemetryCatalog.instance.isValidRecord(record),
          isTrue,
          reason: '镜子事件 ${def.name} 未通过 TelemetryCatalog 校验（可能漂移）',
        );
      }
    });

    test('every mirrored error code is registered', () {
      const errorCodes = <TelemetryErrorCodeDefinition>[
        AppTelemetryErrorCodes.netQuicConnRefused,
        AppTelemetryErrorCodes.netQuicTimeout,
        AppTelemetryErrorCodes.netRelayUnavailable,
        AppTelemetryErrorCodes.sshAuthFailed,
        AppTelemetryErrorCodes.sshHostKeyMismatch,
        AppTelemetryErrorCodes.sshTimeout,
        AppTelemetryErrorCodes.sftpPermissionDenied,
        AppTelemetryErrorCodes.sftpFileNotFound,
        AppTelemetryErrorCodes.sftpTransferAborted,
        AppTelemetryErrorCodes.lanPeerDisconnected,
        AppTelemetryErrorCodes.lanHandshakeFailed,
        AppTelemetryErrorCodes.aiRateLimited,
        AppTelemetryErrorCodes.aiServiceUnavailable,
        AppTelemetryErrorCodes.telemetryAuthFailed,
        AppTelemetryErrorCodes.telemetryNetworkError,
        AppTelemetryErrorCodes.telemetryStorageFull,
      ];

      for (final code in errorCodes) {
        expect(
          TelemetryCatalog.instance.isValidErrorCode(code.code),
          isTrue,
          reason: '镜子错误码 ${code.code} 未在 TelemetryCatalog 注册（可能漂移）',
        );
      }
    });
  });
}

Object _sampleValue(String key) {
  if (key.endsWith('_ms') ||
      key.endsWith('_bytes') ||
      key == 'exit_code' ||
      key == 'rtt_ms' ||
      key == 'retry_count') {
    return 1;
  }
  if (key == 'fallback_used') return true;
  return 'sample';
}