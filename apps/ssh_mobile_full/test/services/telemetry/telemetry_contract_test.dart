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
            for (final entry in definition.propertyTypes.entries)
              entry.key: _sampleValue(entry.value),
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

Object _sampleValue(String type) {
  switch (type) {
    case 'integer':
      return 1;
    case 'boolean':
      return true;
    default:
      return 'sample';
  }
}
