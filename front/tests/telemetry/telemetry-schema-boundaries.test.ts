import { describe, expect, it } from 'vitest';
import {
  TelemetryErrorCodes,
  TelemetryEvents,
  type TelemetryEventDefinition,
} from '../../src/generated/telemetry_contract';
import {
  type TelemetryRecord,
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
});
