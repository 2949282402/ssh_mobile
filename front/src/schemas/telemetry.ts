import { z } from 'zod';
import eventsJson from '../../../contracts/telemetry/events.json';
import errorCodesJson from '../../../contracts/telemetry/error_codes.json';

export const RecordTypeSchema = z.enum(['analytics', 'diagnostic']);
export type RecordType = z.infer<typeof RecordTypeSchema>;

export const SeveritySchema = z.enum(['info', 'warn', 'error', 'critical']);
export type Severity = z.infer<typeof SeveritySchema>;

export const PlatformSchema = z.enum(['ios', 'android', 'macos', 'windows', 'linux']);
export type Platform = z.infer<typeof PlatformSchema>;

export const IngestStatusSchema = z.enum(['accepted', 'already_seen', 'rejected']);
export type IngestStatus = z.infer<typeof IngestStatusSchema>;

export const TelemetryErrorSchema = z.object({
  errorCode: z.string().min(1),
  category: z.string().min(1),
  terminalFailure: z.boolean(),
  message: z.string().optional(),
  stackTrace: z.string().optional(),
});
export type TelemetryError = z.infer<typeof TelemetryErrorSchema>;

export const TelemetryRecordSchema = z.object({
  eventId: z.string().min(1),
  recordType: RecordTypeSchema,
  eventName: z.string().min(1),
  eventVersion: z.number().int().min(1),
  deviceId: z.string().min(1),
  sessionId: z.string().min(1),
  traceId: z.string().min(1),
  occurredAt: z.string().datetime({ offset: true }).or(z.string().min(1)),
  receivedAt: z.string().datetime({ offset: true }).optional(),
  feature: z.string().min(1),
  severity: SeveritySchema,
  appVersion: z.string().min(1),
  buildNumber: z.string().min(1),
  platform: PlatformSchema,
  properties: z.record(z.string(), z.unknown()).default({}),
  error: TelemetryErrorSchema.optional(),
});
export type TelemetryRecord = z.infer<typeof TelemetryRecordSchema>;

export const TelegestResultSchema = z.object({
  eventId: z.string().min(1),
  status: IngestStatusSchema,
  reason: z.string().optional(),
});
export type TelemetryResult = z.infer<typeof TelegestResultSchema>;

export const TelemetryBatchUploadRequestSchema = z.object({
  records: z.array(TelemetryRecordSchema),
});
export type TelemetryBatchUploadRequest = z.infer<typeof TelemetryBatchUploadRequestSchema>;

export const TelemetryBatchUploadResponseSchema = z.object({
  results: z.array(TelegestResultSchema),
});
export type TelemetryBatchUploadResponse = z.infer<typeof TelemetryBatchUploadResponseSchema>;

export const TelemetryUploadPolicySchema = z.object({
  uploadEnabled: z.boolean(),
  batchSizeThreshold: z.number().int().min(1).max(1000),
  timeIntervalSeconds: z.number().int().min(5).max(3600),
  maxBatchSize: z.number().int().min(1).max(1000),
  clientMaxLocalRecords: z.number().int().min(100).max(1000000),
  specialTriggers: z.array(z.string()),
  policyVersion: z.number().int().min(1),
});
export type TelemetryUploadPolicy = z.infer<typeof TelemetryUploadPolicySchema>;

export const TelemetryFilterSchema = z.object({
  timeRange: z.enum(['1h', '24h', '7d', '30d', 'all']).default('24h'),
  startTime: z.string().optional(),
  endTime: z.string().optional(),
  deviceId: z.string().optional(),
  traceId: z.string().optional(),
  eventName: z.string().optional(),
  feature: z.string().optional(),
  severity: SeveritySchema.optional(),
  errorCode: z.string().optional(),
  appVersion: z.string().optional(),
  platform: PlatformSchema.optional(),
  page: z.number().int().min(1).default(1),
  pageSize: z.number().int().min(1).max(200).default(50),
});
export type TelemetryFilter = z.infer<typeof TelemetryFilterSchema>;

export const TelemetryMetricPointSchema = z.object({
  timestamp: z.string(),
  value: z.number(),
});
export type TelemetryMetricPoint = z.infer<typeof TelemetryMetricPointSchema>;

export const TelemetryLatencyStatsSchema = z.object({
  p50Ms: z.number(),
  p95Ms: z.number(),
  p99Ms: z.number(),
  samples: z.number(),
});
export type TelemetryLatencyStats = z.infer<typeof TelemetryLatencyStatsSchema>;

export const TelemetryOverviewResponseSchema = z.object({
  totalEvents: z.number(),
  totalDiagnostics: z.number(),
  recentActiveDevices: z.number(),
  errorCount: z.number(),
  criticalErrorCount: z.number(),
  affectedDevicesCount: z.number(),
  coreOperationSuccessRate: z.number(),
  errorFreeSessionRate: z.number(),
  eventsTrend: z.array(TelemetryMetricPointSchema),
  errorsTrend: z.array(TelemetryMetricPointSchema),
  latency: TelemetryLatencyStatsSchema.optional().default({
    p50Ms: 0,
    p95Ms: 0,
    p99Ms: 0,
    samples: 0,
  }),
  pipelineHealth: z.object({
    status: z.enum(['healthy', 'degraded', 'unhealthy']),
    serverIngestLatencyMs: z.number(),
    serverIngestErrorRate: z.number(),
    redisCacheStatus: z.enum(['active', 'disabled', 'fallback_mysql']),
  }),
});
export type TelemetryOverviewResponse = z.infer<typeof TelemetryOverviewResponseSchema>;

export const TelemetryEventsListResponseSchema = z.object({
  items: z.array(TelemetryRecordSchema),
  total: z.number(),
  page: z.number(),
  pageSize: z.number(),
});
export type TelemetryEventsListResponse = z.infer<typeof TelemetryEventsListResponseSchema>;

export const TelemetryDiagnosticsListResponseSchema = z.object({
  items: z.array(TelemetryRecordSchema),
  total: z.number(),
  page: z.number(),
  pageSize: z.number(),
  source: z.enum(['redis_cache', 'mysql']),
});
export type TelemetryDiagnosticsListResponse = z.infer<typeof TelemetryDiagnosticsListResponseSchema>;

export const TelemetrySettingsSchema = z.object({
  policy: TelemetryUploadPolicySchema,
  retentionDays: z.number().int().min(1).max(3650),
  retentionMaxRows: z.number().int().min(1000).max(100000000),
  retentionTimeEnabled: z.boolean(),
  retentionRowsEnabled: z.boolean(),
  redisCacheEnabled: z.boolean(),
  redisMaxRecords: z.number().int().min(10).max(10000),
  updatedAt: z.string(),
});
export type TelemetrySettings = z.infer<typeof TelemetrySettingsSchema>;

const registeredEventsMap = new Map<string, (typeof eventsJson.events)[0]>(
  eventsJson.events.map((ev) => [ev.name, ev])
);

const registeredErrorsMap = new Map<string, (typeof errorCodesJson.errorCodes)[0]>(
  errorCodesJson.errorCodes.map((err) => [err.code, err])
);

export function validateEventCatalogRecord(record: TelemetryRecord): { valid: boolean; error?: string } {
  const def = registeredEventsMap.get(record.eventName);
  if (!def) {
    return { valid: false, error: `Unregistered event name: ${record.eventName}` };
  }

  if (record.eventVersion !== def.version) {
    return { valid: false, error: `Event version mismatch for ${record.eventName}: expected ${def.version}, got ${record.eventVersion}` };
  }

  const allowedProps = new Set(def.allowedProperties.map((p) => p.name));
  for (const key of Object.keys(record.properties || {})) {
    if (!allowedProps.has(key)) {
      return { valid: false, error: `Unregistered property "${key}" for event "${record.eventName}"` };
    }
  }

  if (record.error) {
    if (!registeredErrorsMap.has(record.error.errorCode)) {
      return { valid: false, error: `Unregistered error code: ${record.error.errorCode}` };
    }
  }

  return { valid: true };
}
