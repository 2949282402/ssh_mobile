import { describe, expect, it } from 'vitest';
import eventsJson from '../../../contracts/telemetry/events.json';
import errorCodesJson from '../../../contracts/telemetry/error_codes.json';
import policySchemaJson from '../../../contracts/telemetry/policy.schema.json';
import {
  TelemetryUploadPolicySchema,
  TelemetryRecordSchema,
  TelemetryBatchUploadRequestSchema,
  TelemetryBatchUploadResponseSchema,
  validateEventCatalogRecord,
} from './telemetry';

describe('Telemetry Contract & Schemas', () => {
  it('loads valid contract definitions from JSON source of truth', () => {
    expect(eventsJson.events.length).toBeGreaterThan(0);
    expect(errorCodesJson.errorCodes.length).toBeGreaterThan(0);
    expect(policySchemaJson.properties.uploadEnabled).toBeDefined();
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
      maxBatchSize: 2000, // max is 1000
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
      eventName: 'ssh.session.started',
      eventVersion: 1,
      deviceId: 'dev_123456',
      sessionId: 'sess_abcdef',
      traceId: 'trace_xyz789',
      occurredAt: new Date().toISOString(),
      feature: 'ssh',
      severity: 'info' as const,
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
      eventName: 'ssh.session.started',
      eventVersion: 1,
      deviceId: 'dev_123456',
      sessionId: 'sess_abcdef',
      traceId: 'trace_xyz789',
      occurredAt: new Date().toISOString(),
      feature: 'ssh',
      severity: 'info' as const,
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

  it('validates batch request and response shape', () => {
    const req = {
      records: [
        {
          eventId: '550e8400-e29b-41d4-a716-446655440000',
          recordType: 'analytics' as const,
          eventName: 'app.lifecycle.started',
          eventVersion: 1,
          deviceId: 'dev_123456',
          sessionId: 'sess_abcdef',
          traceId: 'trace_xyz789',
          occurredAt: new Date().toISOString(),
          feature: 'app',
          severity: 'info' as const,
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
