import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TelemetryEventRecord record({required Map<String, dynamic> properties}) {
    final event = TelemetryEvents.networkQuicConnected;
    return TelemetryEventRecord(
      eventId: 'property-types-event',
      recordType: event.recordType,
      eventName: event.name,
      eventVersion: event.version,
      deviceId: 'property-types-device',
      sessionId: 'property-types-session',
      traceId: 'property-types-trace',
      occurredAt: DateTime.utc(2026, 8, 28),
      feature: event.feature,
      severity: event.severity,
      appVersion: '1.0.0',
      buildNumber: '1',
      platform: 'linux',
      properties: properties,
    );
  }

  test('generated definitions carry primitive property types', () {
    for (final event in TelemetryEvents.all) {
      expect(
        event.propertyTypes.keys,
        containsAll(event.allowedProperties),
        reason: 'missing property type for ${event.name}',
      );
    }
  });

  test(
    'catalog rejects values whose primitive type differs from the contract',
    () {
      final catalog = TelemetryCatalog.instance;
      expect(
        catalog.isValidRecord(
          record(properties: {'rtt_ms': 15, 'protocol_version': 'v2'}),
        ),
        isTrue,
      );
      expect(
        catalog.isValidRecord(
          record(properties: {'rtt_ms': '15', 'protocol_version': 'v2'}),
        ),
        isFalse,
      );
      expect(
        catalog.isValidRecord(
          record(properties: {'rtt_ms': 15.5, 'protocol_version': 'v2'}),
        ),
        isFalse,
      );
      expect(
        catalog.isValidRecord(
          record(properties: {'rtt_ms': 15, 'protocol_version': true}),
        ),
        isFalse,
      );
    },
  );
}
