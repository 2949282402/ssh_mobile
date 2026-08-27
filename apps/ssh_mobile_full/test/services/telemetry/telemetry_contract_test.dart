// Generated telemetry contract integration tests for the Full App.

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('generated telemetry contract', () {
    test('every generated event passes strict catalog validation', () {
      for (final definition in TelemetryEvents.all) {
        final record = TelemetryEventRecord(
          eventId: 'probe',
          recordType: definition.recordType,
          eventName: definition.name,
          eventVersion: definition.version,
          deviceId: 'dev',
          sessionId: 'sess',
          traceId: 'trace',
          occurredAt: DateTime.now().toUtc(),
          feature: definition.feature,
          severity: definition.severity,
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'linux',
          properties: {
            for (final key in definition.allowedProperties)
              key: _sampleValue(key),
          },
        );
        expect(
          TelemetryCatalog.instance.isValidRecord(record),
          isTrue,
          reason: 'generated event ${definition.name} failed validation',
        );
      }
    });

    test('every generated error code is registered with exact metadata', () {
      for (final definition in TelemetryErrorCodes.all) {
        expect(
          TelemetryCatalog.instance.isValidErrorCode(definition.code),
          isTrue,
          reason: 'generated error ${definition.code} is not registered',
        );
      }
      expect(TelemetryErrorCodes.sshConnectFailed.category, 'ssh');
      expect(TelemetryErrorCodes.appFatalError.terminalFailure, isTrue);
    });

    test('operation metadata is generated for dashboard consumers', () {
      expect(
        TelemetryEvents.networkRelayFailed.operationGroup,
        'network.relay',
      );
      expect(TelemetryEvents.networkRelayFailed.operationRole, 'failure');
      expect(TelemetryEvents.sshSessionConnected.operationRole, 'success');
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
