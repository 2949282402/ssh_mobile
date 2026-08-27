import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TelemetryModel', () {
    test('TelemetrySyncState exposes new_ wire value new', () {
      expect(TelemetrySyncState.new_.wireValue, 'new');
      expect(TelemetrySyncState.pending.wireValue, 'pending');
      expect(TelemetrySyncState.synced.wireValue, 'synced');
      expect(TelemetrySyncState.rejected.wireValue, 'rejected');
    });

    test('TelemetrySyncState.fromWireValue round-trips', () {
      expect(TelemetrySyncState.fromWireValue('new'), TelemetrySyncState.new_);
      expect(
        TelemetrySyncState.fromWireValue('pending'),
        TelemetrySyncState.pending,
      );
      expect(
        TelemetrySyncState.fromWireValue('synced'),
        TelemetrySyncState.synced,
      );
      expect(
        TelemetrySyncState.fromWireValue('rejected'),
        TelemetrySyncState.rejected,
      );
      // 未知值回退到 pending
      expect(
        TelemetrySyncState.fromWireValue('unknown'),
        TelemetrySyncState.pending,
      );
    });

    test(
      'TelemetryEventRecord defaults to pending with null logicalDeletedAt',
      () {
        final record = TelemetryEventRecord(
          eventId: 'evt-1',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: DateTime.parse('2026-08-27T10:00:00.000Z'),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        expect(record.syncState, TelemetrySyncState.pending);
        expect(record.logicalDeletedAt, isNull);
        expect(record.retryCount, 0);
      },
    );

    test('copyWith clears logicalDeletedAt when requested', () {
      final original = TelemetryEventRecord(
        eventId: 'evt-1',
        recordType: TelemetryRecordType.analytics,
        eventName: 'ssh.session.started',
        eventVersion: 1,
        deviceId: 'dev-1',
        sessionId: 'sess-1',
        traceId: 'trace-1',
        occurredAt: DateTime.now(),
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        appVersion: '1.0.0',
        buildNumber: '100',
        platform: 'android',
      );
      final synced = original.copyWith(
        syncState: TelemetrySyncState.synced,
        logicalDeletedAt: DateTime.now().toUtc(),
      );
      expect(synced.logicalDeletedAt, isNotNull);

      final backToPending = synced.copyWith(
        syncState: TelemetrySyncState.rejected,
        clearLogicalDeletedAt: true,
      );
      expect(backToPending.logicalDeletedAt, isNull);
    });

    test('copyWith resets retryCount', () {
      final record = TelemetryEventRecord(
        eventId: 'evt-1',
        recordType: TelemetryRecordType.analytics,
        eventName: 'ssh.session.started',
        eventVersion: 1,
        deviceId: 'dev-1',
        sessionId: 'sess-1',
        traceId: 'trace-1',
        occurredAt: DateTime.now(),
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        appVersion: '1.0.0',
        buildNumber: '100',
        platform: 'android',
        retryCount: 5,
      );
      expect(record.copyWith(retryCount: 0).retryCount, 0);
    });
  });
}
