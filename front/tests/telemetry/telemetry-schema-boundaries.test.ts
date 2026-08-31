import { describe, expect, it } from 'vitest';
import {
  TelemetryErrorCodes,
  TelemetryEvents,
  type TelemetryEventDefinition,
} from '../../src/generated/telemetry_contract';
import {
  TelemetryErrorSchema,
  type TelemetryRecord,
  TelemetryRecordSchema,
  validateEventCatalogRecord,
} from '../../src/schemas/telemetry';

function recordFor(definition: TelemetryEventDefinition): TelemetryRecord {
  return {
    eventId: `event-${definition.name}`,
    recordType: definition.recordType,
    eventName: definition.name,
    eventVersion: definition.version,
    deviceId: 'device-schema-boundary',
    sessionId: 'session-schema-boundary',
    traceId: 'trace-schema-boundary',
    occurredAt: '2026-08-28T00:00:00Z',
    feature: definition.feature,
    severity: definition.severity,
    appVersion: '1.0.0',
    buildNumber: '100',
    platform: 'linux',
    properties: {},
  };
}

describe('telemetry catalog validation boundaries', () => {
  it('rejects unknown names and every event metadata mismatch', () => {
    const definition = TelemetryEvents.networkRelayFailed;
    const record = recordFor(definition);

    expect(validateEventCatalogRecord({ ...record, eventName: 'event.not.registered' })).toMatchObject({
      valid: false,
      error: 'Unregistered event name: event.not.registered',
    });
    expect(validateEventCatalogRecord({ ...record, eventVersion: definition.version + 1 })).toMatchObject({ valid: false });
    expect(validateEventCatalogRecord({ ...record, recordType: 'analytics' })).toMatchObject({ valid: false });
    expect(validateEventCatalogRecord({ ...record, feature: 'ssh' })).toMatchObject({ valid: false });
    expect(validateEventCatalogRecord({ ...record, severity: 'critical' })).toMatchObject({ valid: false });
  });

  it('requires catalog-declared properties before accepting a record', () => {
    const definition = TelemetryEvents.sftpTransferFailed;
    const result = validateEventCatalogRecord(recordFor(definition));

    expect(result).toMatchObject({ valid: false });
    expect(result.error).toContain('Missing required property "direction"');
  });

  it('rejects an error code that is absent from the catalog', () => {
    const record = {
      ...recordFor(TelemetryEvents.networkRelayFailed),
      error: {
        errorCode: 'UNKNOWN_ERROR_CODE',
        category: TelemetryErrorCodes.netRelayUnavailable.category,
        terminalFailure: TelemetryErrorCodes.netRelayUnavailable.terminalFailure,
      },
    };

    expect(validateEventCatalogRecord(record)).toMatchObject({
      valid: false,
      error: 'Unregistered error code: UNKNOWN_ERROR_CODE',
    });
  });

  it('rejects property values whose primitive type differs from the generated contract', () => {
    const definition = TelemetryEvents.networkQuicConnected;
    const record = recordFor(definition);

    expect(
      validateEventCatalogRecord({
        ...record,
        properties: { rtt_ms: '15', protocol_version: 'v2' },
      }),
    ).toMatchObject({ valid: false });
    expect(
      validateEventCatalogRecord({
        ...record,
        properties: { rtt_ms: 15.5, protocol_version: 'v2' },
      }),
    ).toMatchObject({ valid: false });
    expect(
      validateEventCatalogRecord({
        ...record,
        properties: { rtt_ms: 15.0, protocol_version: 'v2' },
      }),
    ).toMatchObject({ valid: true });
    expect(
      validateEventCatalogRecord({
        ...record,
        properties: { rtt_ms: 15, protocol_version: true },
      }),
    ).toMatchObject({ valid: false });
  });

  it('schema accepts only primitive telemetry property values', () => {
    const definition = TelemetryEvents.networkQuicConnected;
    const record = recordFor(definition);

    expect(
      TelemetryRecordSchema.safeParse({
        ...record,
        properties: { rtt_ms: 15, protocol_version: 'v2' },
      }).success,
    ).toBe(true);
    expect(
      TelemetryRecordSchema.safeParse({
        ...record,
        properties: { rtt_ms: { value: 15 } },
      }).success,
    ).toBe(false);
  });

  it('bounds diagnostic error message and stack text', () => {
    const definition = TelemetryEvents.networkQuicConnected;
    const record = recordFor(definition);
    const error = {
      errorCode: 'APP_UNCAUGHT_ERROR',
      category: 'app',
      terminalFailure: false,
    };

    expect(
      TelemetryRecordSchema.safeParse({
        ...record,
        error: {
          ...error,
          message: 'm'.repeat(513),
        },
      }).success,
    ).toBe(false);
    expect(
      TelemetryErrorSchema.safeParse({
        ...error,
        stackTrace: 's'.repeat(513),
      }).success,
    ).toBe(false);
  });
});
