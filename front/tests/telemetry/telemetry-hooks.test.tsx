import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  useTelemetryOverview,
  useTelemetryEvents,
  useTelemetryDiagnostics,
  useTelemetrySettings,
  useUpdateTelemetrySettings,
} from '../../src/hooks/use-telemetry';

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

function createWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false },
    },
  });
  return function Wrapper({ children }: { children: ReactNode }) {
    return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
  };
}

describe('telemetry hooks', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('fetches telemetry overview and passes filter parameters', async () => {
    const mockOverview = {
      totalEvents: 50,
      totalDiagnostics: 10,
      recentActiveDevices: 3,
      errorCount: 1,
      criticalErrorCount: 0,
      affectedDevicesCount: 1,
      coreOperationSuccessRate: 1.0,
      businessOperationSuccessRate: 1.0,
      businessOperationSuccesses: 10,
      businessOperationFailures: 0,
      businessOperationDenominator: 10,
      businessOperationGroups: [],
      errorFreeSessionRate: 0.9,
      errorFreeSessionSuccesses: 9,
      errorFreeSessionDenominator: 10,
      eventsTrend: [],
      errorsTrend: [],
      latency: { p50Ms: 0, p95Ms: 0, p99Ms: 0, samples: 0 },
      pipelineHealth: {
        status: 'healthy',
        serverIngestLatencyMs: 2.5,
        serverIngestLatencyP50Ms: 2,
        serverIngestLatencyP95Ms: 4,
        serverIngestLatencyP99Ms: 5,
        serverIngestLatencySamples: 10,
        serverIngestRequests: 10,
        serverIngestSuccesses: 10,
        serverIngestFailures: 0,
        serverIngestErrorRate: 0.0,
        redisCacheStatus: 'active',
      },
      deliveryDelay: {
        averageMs: 10,
        p50Ms: 8,
        p95Ms: 20,
        p99Ms: 25,
        samples: 10,
        futureTimestampCount: 0,
      },
    };

    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockOverview));
    vi.stubGlobal('fetch', fetchMock);

    const { result } = renderHook(() => useTelemetryOverview({ timeRange: '7d' }), {
      wrapper: createWrapper(),
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data).toEqual(mockOverview);
    expect(fetchMock.mock.calls[0][0]).toContain('/api/admin/v1/telemetry/overview?timeRange=7d');
  });

  it('fetches telemetry events with filters and pagination', async () => {
    const mockEvents = {
      items: [],
      total: 0,
      page: 1,
      pageSize: 50,
    };

    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockEvents));
    vi.stubGlobal('fetch', fetchMock);

    const { result } = renderHook(() => useTelemetryEvents({ page: 1, pageSize: 50, feature: 'auth' }), {
      wrapper: createWrapper(),
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data).toEqual(mockEvents);
    expect(fetchMock.mock.calls[0][0]).toContain('/api/admin/v1/telemetry/events?page=1&pageSize=50&feature=auth');
  });

  it('fetches telemetry diagnostics logs with filters', async () => {
    const mockDiagnostics = {
      items: [],
      total: 0,
      page: 1,
      pageSize: 20,
      source: 'redis_cache',
    };

    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockDiagnostics));
    vi.stubGlobal('fetch', fetchMock);

    const { result } = renderHook(() => useTelemetryDiagnostics({ severity: 'error' }), {
      wrapper: createWrapper(),
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data?.source).toBe('redis_cache');
    expect(fetchMock.mock.calls[0][0]).toContain('/api/admin/v1/telemetry/diagnostics?severity=error');
  });

  it('fetches and updates telemetry settings mutation', async () => {
    const mockSettings = {
      policy: {
        uploadEnabled: true,
        batchSizeThreshold: 50,
        timeIntervalSeconds: 60,
        maxBatchSize: 100,
        clientMaxLocalRecords: 10000,
        specialTriggers: [],
        policyVersion: 1,
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
      .mockResolvedValueOnce(jsonResponse({ status: 'ok' }))
      .mockResolvedValueOnce(jsonResponse(mockSettings));
    vi.stubGlobal('fetch', fetchMock);

    const wrapper = createWrapper();
    const { result: settingsResult } = renderHook(() => useTelemetrySettings(), { wrapper });
    await waitFor(() => expect(settingsResult.current.isSuccess).toBe(true));
    expect(settingsResult.current.data).toEqual(mockSettings);

    const { result: mutationResult } = renderHook(() => useUpdateTelemetrySettings(), { wrapper });
    await act(async () => {
      await mutationResult.current.mutateAsync(mockSettings);
    });

    // Initial query (1) + Mutation (2) + Invalidation refetch (3)
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3));
  });
});
