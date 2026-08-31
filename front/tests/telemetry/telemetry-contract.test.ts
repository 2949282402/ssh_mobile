import { describe, expect, it } from 'vitest';
import policySchemaJson from '../../../contracts/telemetry/policy.schema.json';
import {
  TelemetryErrorCodes,
  TelemetryEvents,
} from '../../src/generated/telemetry_contract';
import {
  TelemetryUploadPolicySchema,
  TelemetryRecordSchema,
  TelemetryBatchUploadRequestSchema,
  TelemetryBatchUploadResponseSchema,
  TelemetryFilterSchema,
  TelemetryOverviewResponseSchema,
  validateEventCatalogRecord,
} from '../../src/schemas/telemetry';

describe('Telemetry Contract & Schemas', () => {
  it('loads valid generated contract definitions', () => {
    expect(TelemetryEvents.all.length).toBeGreaterThan(0);
    expect(TelemetryErrorCodes.all.length).toBeGreaterThan(0);
    expect(policySchemaJson.properties.uploadEnabled).toBeDefined();
  });

  it('exposes operation metadata and precise failure definitions', () => {
    expect(TelemetryEvents.networkRelayFailed.operationGroup).toBe('network.relay');
    expect(TelemetryEvents.networkRelayFailed.operationRole).toBe('failure');
    expect(TelemetryEvents.networkRelayFailed.businessOperation).toBe(true);
    expect(TelemetryEvents.networkRelayFallback.businessOperation).toBe(false);
    expect(TelemetryEvents.sshSessionConnected.operationRole).toBe('success');
    expect(TelemetryErrorCodes.sshConnectFailed.category).toBe('ssh');
    expect(TelemetryErrorCodes.appFatalError.terminalFailure).toBe(true);
  });

  it('documents the compatibility alias and supports the one-day trend range', () => {
    expect(TelemetryOverviewResponseSchema.shape.coreOperationSuccessRate.description).toContain('Deprecated');
    expect(TelemetryFilterSchema.parse({ timeRange: '1d' }).timeRange).toBe('1d');
  });

  it('validates a correct telemetry upload policy', () => {
    const validPolicy = {
      uploadEnabled: true,
      batchSizeThreshold: 50,
      timeIntervalSeconds: 60,
      maxBatchSize: 100,
      clientMaxLocalRecords: 10000,
      specialTriggers: ['highPriorityError', 'appBackground'],
      policyVersion: 1,
    };

    const parsed = TelemetryUploadPolicySchema.parse(validPolicy);
    expect(parsed.uploadEnabled).toBe(true);
    expect(parsed.batchSizeThreshold).toBe(50);
  });

  it('rejects invalid policy thresholds', () => {
    const invalidPolicy = {
      uploadEnabled: true,
      batchSizeThreshold: 0, // min is 1
      timeIntervalSeconds: 1, // min is 5
      maxBatchSize: 2000, // max is 100
      clientMaxLocalRecords: 10, // min is 100
      specialTriggers: ['invalid_trigger'],
      policyVersion: 0,
    };

    expect(() => TelemetryUploadPolicySchema.parse(invalidPolicy)).toThrow();
  });

  it('validates a well-formed telemetry record against schema and catalog', () => {
    const record = {
      eventId: '550e8400-e29b-41d4-a716-446655440000',
      recordType: 'analytics' as const,
      eventName: TelemetryEvents.sshSessionStarted.name,
      eventVersion: TelemetryEvents.sshSessionStarted.version,
      deviceId: 'dev_123456',
      sessionId: 'sess_abcdef',
      traceId: 'trace_xyz789',
      occurredAt: new Date().toISOString(),
      feature: TelemetryEvents.sshSessionStarted.feature,
      severity: TelemetryEvents.sshSessionStarted.severity,
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'android' as const,
      properties: {
        session_type: 'interactive',
        auth_method: 'publickey',
      },
    };

    const parsed = TelemetryRecordSchema.parse(record);
    expect(parsed.eventId).toBe(record.eventId);

    const validationResult = validateEventCatalogRecord(record);
    expect(validationResult.valid).toBe(true);
  });

  it('rejects an unregistered property in record catalog validation', () => {
    const record = {
      eventId: '550e8400-e29b-41d4-a716-446655440001',
      recordType: 'analytics' as const,
      eventName: TelemetryEvents.sshSessionStarted.name,
      eventVersion: TelemetryEvents.sshSessionStarted.version,
      deviceId: 'dev_123456',
      sessionId: 'sess_abcdef',
      traceId: 'trace_xyz789',
      occurredAt: new Date().toISOString(),
      feature: TelemetryEvents.sshSessionStarted.feature,
      severity: TelemetryEvents.sshSessionStarted.severity,
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'android' as const,
      properties: {
        session_type: 'interactive',
        unregistered_field: 'leak_candidate',
      },
    };

    const validationResult = validateEventCatalogRecord(record);
    expect(validationResult.valid).toBe(false);
    expect(validationResult.error).toContain('unregistered_field');
  });

  it('rejects event metadata and error metadata mismatches', () => {
    const event = TelemetryEvents.networkRelayFailed;
    const error = TelemetryErrorCodes.netRelayUnavailable;
    const record = {
      eventId: '550e8400-e29b-41d4-a716-446655440002',
      recordType: event.recordType,
      eventName: event.name,
      eventVersion: event.version,
      deviceId: 'dev_123456',
      sessionId: 'sess_abcdef',
      traceId: 'trace_xyz789',
      occurredAt: new Date().toISOString(),
      feature: event.feature,
      severity: event.severity,
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'android' as const,
      properties: {},
      error: {
        errorCode: error.code,
        category: error.category,
        terminalFailure: error.terminalFailure,
      },
    };

    expect(
      validateEventCatalogRecord({ ...record, feature: 'ssh' }),
    ).toMatchObject({ valid: false });
    expect(
      validateEventCatalogRecord({
        ...record,
        error: { ...record.error, category: 'ssh' },
      }),
    ).toMatchObject({ valid: false });
    expect(
      validateEventCatalogRecord({
        ...record,
        error: { ...record.error, terminalFailure: false },
      }),
    ).toMatchObject({ valid: false });
  });

  it('validates batch request and response shape', () => {
    const req = {
      records: [
        {
          eventId: '550e8400-e29b-41d4-a716-446655440000',
          recordType: 'analytics' as const,
          eventName: TelemetryEvents.appLifecycleStarted.name,
          eventVersion: TelemetryEvents.appLifecycleStarted.version,
          deviceId: 'dev_123456',
          sessionId: 'sess_abcdef',
          traceId: 'trace_xyz789',
          occurredAt: new Date().toISOString(),
          feature: TelemetryEvents.appLifecycleStarted.feature,
          severity: TelemetryEvents.appLifecycleStarted.severity,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'ios' as const,
          properties: {
            cold_start: true,
          },
        },
      ],
    };

    const parsedReq = TelemetryBatchUploadRequestSchema.parse(req);
    expect(parsedReq.records.length).toBe(1);

    const res = {
      results: [
        {
          eventId: '550e8400-e29b-41d4-a716-446655440000',
          status: 'accepted' as const,
        },
      ],
    };

    const parsedRes = TelemetryBatchUploadResponseSchema.parse(res);
    expect(parsedRes.results[0].status).toBe('accepted');
  });
});
