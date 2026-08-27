import { describe, expect, it, vi } from 'vitest';
import { telemetryApi } from './telemetry';
import { AdminApiRoutes } from './routes';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

describe('telemetryApi', () => {
  it('fetches overview metrics with query parameters', async () => {
    const mockData = {
      totalEvents: 100,
      totalDiagnostics: 20,
      recentActiveDevices: 5,
      errorCount: 2,
      criticalErrorCount: 0,
      affectedDevicesCount: 1,
      coreOperationSuccessRate: 0.98,
      errorFreeSessionRate: 0.95,
      eventsTrend: [{ timestamp: '2026-08-27T00:00:00Z', value: 100 }],
      errorsTrend: [{ timestamp: '2026-08-27T00:00:00Z', value: 2 }],
      latency: { p50Ms: 120, p95Ms: 340, p99Ms: 512, samples: 12 },
      pipelineHealth: {
        status: 'healthy',
        serverIngestLatencyMs: 4.2,
        serverIngestErrorRate: 0.0,
        redisCacheStatus: 'active',
      },
    };

    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockData));
    vi.stubGlobal('fetch', fetchMock);

    const res = await telemetryApi.getOverview({ timeRange: '24h', feature: 'terminal' });
    expect(res).toEqual(mockData);
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining(`${AdminApiRoutes.telemetry.overview}?`),
      expect.objectContaining({
        credentials: 'include',
      }),
    );
    const calledUrl = fetchMock.mock.calls[0][0] as string;
    expect(calledUrl).toContain('timeRange=24h');
    expect(calledUrl).toContain('feature=terminal');
  });

  it('fetches events list with pagination and filters', async () => {
    const mockRecord = {
      eventId: 'evt-1',
      recordType: 'analytics',
      eventName: 'terminal_session_opened',
      eventVersion: 1,
      deviceId: 'dev-1',
      sessionId: 'sess-1',
      traceId: 'trace-1',
      occurredAt: '2026-08-27T00:00:00Z',
      feature: 'terminal',
      severity: 'info',
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'android',
      properties: { protocol: 'v2' },
    };

    const mockResponse = {
      items: [mockRecord],
      total: 1,
      page: 1,
      pageSize: 50,
    };

    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockResponse));
    vi.stubGlobal('fetch', fetchMock);

    const res = await telemetryApi.getEvents({ page: 1, pageSize: 50, eventName: 'terminal_session_opened' });
    expect(res).toEqual(mockResponse);
    const calledUrl = fetchMock.mock.calls[0][0] as string;
    expect(calledUrl).toContain(`${AdminApiRoutes.telemetry.events}?`);
    expect(calledUrl).toContain('eventName=terminal_session_opened');
  });

  it('fetches diagnostics logs with source indicator', async () => {
    const mockRecord = {
      eventId: 'diag-1',
      recordType: 'diagnostic',
      eventName: 'ssh_error_occurred',
      eventVersion: 1,
      deviceId: 'dev-1',
      sessionId: 'sess-1',
      traceId: 'trace-1',
      occurredAt: '2026-08-27T00:00:00Z',
      feature: 'ssh',
      severity: 'error',
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'linux',
      properties: {},
      error: {
        errorCode: 'ERR_SSH_HANDSHAKE_TIMEOUT',
        category: 'timeout',
        terminalFailure: false,
        message: 'handshake timed out',
      },
    };

    const mockResponse = {
      items: [mockRecord],
      total: 1,
      page: 1,
      pageSize: 20,
      source: 'redis_cache',
    };

    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockResponse));
    vi.stubGlobal('fetch', fetchMock);

    const res = await telemetryApi.getDiagnostics({ severity: 'error' });
    expect(res).toEqual(mockResponse);
    expect(res.source).toBe('redis_cache');
  });

  it('fetches and updates telemetry settings', async () => {
    const mockSettings = {
      policy: {
        uploadEnabled: true,
        batchSizeThreshold: 50,
        timeIntervalSeconds: 60,
        maxBatchSize: 100,
        clientMaxLocalRecords: 10000,
        specialTriggers: ['highPriorityError'],
        policyVersion: 2,
      },
      retentionDays: 30,
      retentionMaxRows: 500000,
      retentionTimeEnabled: true,
      retentionRowsEnabled: true,
      redisCacheEnabled: true,
      redisMaxRecords: 1000,
      updatedAt: '2026-08-27T00:00:00Z',
    };

    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(mockSettings))
      .mockResolvedValueOnce(jsonResponse({ status: 'ok' }));
    vi.stubGlobal('fetch', fetchMock);

    const settings = await telemetryApi.getSettings();
    expect(settings).toEqual(mockSettings);
    expect(fetchMock).toHaveBeenNthCalledWith(1, AdminApiRoutes.telemetry.settings, expect.anything());

    await telemetryApi.updateSettings(mockSettings);
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      AdminApiRoutes.telemetry.settings,
      expect.objectContaining({
        method: 'PUT',
        body: JSON.stringify(mockSettings),
      }),
    );
  });
});
