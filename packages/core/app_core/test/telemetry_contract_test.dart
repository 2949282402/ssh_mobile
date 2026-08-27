import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Telemetry Contract & Catalog', () {
    test('TelemetryEventRecord serializes and deserializes correctly', () {
      final record = TelemetryEventRecord(
        eventId: '550e8400-e29b-41d4-a716-446655440000',
        recordType: TelemetryRecordType.analytics,
        eventName: 'ssh.session.started',
        eventVersion: 1,
        deviceId: 'dev_123456',
        sessionId: 'sess_abcdef',
        traceId: 'trace_xyz789',
        occurredAt: DateTime.parse('2026-08-27T10:00:00.000Z'),
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        appVersion: '1.0.0',
        buildNumber: '100',
        platform: 'android',
        properties: {'session_type': 'interactive', 'auth_method': 'publickey'},
      );

      final json = record.toJson();
      expect(json['eventId'], '550e8400-e29b-41d4-a716-446655440000');
      expect(json['recordType'], 'analytics');
      expect(json['eventName'], 'ssh.session.started');
      expect(json['properties']['session_type'], 'interactive');

      final reconstructed = TelemetryEventRecord.fromJson(json);
      expect(reconstructed.eventId, record.eventId);
      expect(reconstructed.recordType, record.recordType);
      expect(reconstructed.eventName, record.eventName);
      expect(reconstructed.severity, record.severity);
      expect(reconstructed.properties['session_type'], 'interactive');
    });

    test('TelemetryCatalog validates registered events and properties', () {
      final catalog = TelemetryCatalog.instance;

      final validRecord = TelemetryEventRecord(
        eventId: '550e8400-e29b-41d4-a716-446655440000',
        recordType: TelemetryRecordType.analytics,
        eventName: 'ssh.session.started',
        eventVersion: 1,
        deviceId: 'dev_123456',
        sessionId: 'sess_abcdef',
        traceId: 'trace_xyz789',
        occurredAt: DateTime.now(),
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        appVersion: '1.0.0',
        buildNumber: '100',
        platform: 'android',
        properties: {'session_type': 'interactive'},
      );

      expect(catalog.isValidRecord(validRecord), isTrue);

      final invalidRecord = TelemetryEventRecord(
        eventId: '550e8400-e29b-41d4-a716-446655440001',
        recordType: TelemetryRecordType.analytics,
        eventName: 'ssh.session.started',
        eventVersion: 1,
        deviceId: 'dev_123456',
        sessionId: 'sess_abcdef',
        traceId: 'trace_xyz789',
        occurredAt: DateTime.now(),
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        appVersion: '1.0.0',
        buildNumber: '100',
        platform: 'android',
        properties: {'unknown_property': 'leak_data'},
      );

      expect(catalog.isValidRecord(invalidRecord), isFalse);
    });

    test('TelemetryCatalog validates error codes', () {
      final catalog = TelemetryCatalog.instance;
      expect(catalog.isValidErrorCode('SSH_AUTH_FAILED'), isTrue);
      expect(catalog.isTerminalFailure('SSH_AUTH_FAILED'), isTrue);
      expect(catalog.isValidErrorCode('UNKNOWN_RANDOM_CODE'), isFalse);
    });

    test('TelemetryUploadPolicy parses and provides safe defaults', () {
      final defaultPolicy = TelemetryUploadPolicy.defaultPolicy();
      expect(defaultPolicy.uploadEnabled, isTrue);
      expect(defaultPolicy.batchSizeThreshold, 50);
      expect(defaultPolicy.timeIntervalSeconds, 60);
      expect(defaultPolicy.maxBatchSize, 100);
      expect(defaultPolicy.clientMaxLocalRecords, 10000);
      expect(defaultPolicy.specialTriggers, contains('highPriorityError'));

      final customJson = {
        'uploadEnabled': false,
        'batchSizeThreshold': 20,
        'timeIntervalSeconds': 30,
        'maxBatchSize': 50,
        'clientMaxLocalRecords': 5000,
        'specialTriggers': ['highPriorityError'],
        'policyVersion': 2,
      };

      final customPolicy = TelemetryUploadPolicy.fromJson(customJson);
      expect(customPolicy.uploadEnabled, isFalse);
      expect(customPolicy.batchSizeThreshold, 20);
      expect(customPolicy.policyVersion, 2);
    });
  });
}
