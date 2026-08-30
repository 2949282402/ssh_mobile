import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactNode } from 'react';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../src/components/toast';
import { TelemetryDashboardPage } from '../../src/features/telemetry/telemetry-dashboard-page';
import { TelemetryEventsPage } from '../../src/features/telemetry/telemetry-events-page';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const boundaryOverview = {
  totalEvents: 864000,
  totalDiagnostics: 0,
  recentActiveDevices: 0,
  errorCount: 0,
  criticalErrorCount: 0,
  affectedDevicesCount: 0,
  coreOperationSuccessRate: 0,
  businessOperationSuccessRate: 0,
  businessOperationSuccesses: 0,
  businessOperationFailures: 0,
  businessOperationDenominator: 0,
  businessOperationGroups: [],
  errorFreeSessionRate: 0,
  errorFreeSessionSuccesses: 0,
  errorFreeSessionDenominator: 0,
  eventsTrend: [
    { timestamp: 'not-a-date', value: 900000 },
    { timestamp: '2026-08-27 00:00:00', value: -1 },
  ],
  errorsTrend: [{ timestamp: '2026-08-27T00:00:00Z', value: 0 }],
  latency: { p50Ms: 1000, p95Ms: 1500, p99Ms: 2000, samples: 1 },
  pipelineHealth: {
    status: 'unhealthy',
    serverIngestLatencyMs: 25,
    serverIngestLatencyP50Ms: 25,
    serverIngestLatencyP95Ms: 55,
    serverIngestLatencyP99Ms: 80,
    serverIngestLatencySamples: 1,
    serverIngestRequests: 1,
    serverIngestSuccesses: 0,
    serverIngestFailures: 1,
    serverIngestErrorRate: 1,
    redisCacheStatus: 'fallback_mysql',
  },
  deliveryDelay: {
    averageMs: 1000,
    p50Ms: 1500,
    p95Ms: 2000,
    p99Ms: 2500,
    samples: 1,
    futureTimestampCount: 0,
  },
};

const emptyOverview = {
  ...boundaryOverview,
  totalEvents: 0,
  eventsTrend: [{ timestamp: '2026-08-27T00:00:00Z', value: 0 }],
  errorsTrend: [{ timestamp: '2026-08-27T00:00:00Z', value: 0 }],
  latency: { p50Ms: 0, p95Ms: 0, p99Ms: 0, samples: 0 },
  pipelineHealth: {
    ...boundaryOverview.pipelineHealth,
    status: 'degraded',
    serverIngestLatencyMs: 0,
    serverIngestLatencyP50Ms: 0,
    serverIngestLatencyP95Ms: 0,
    serverIngestLatencyP99Ms: 0,
    serverIngestLatencySamples: 0,
    serverIngestRequests: 0,
    serverIngestSuccesses: 0,
    serverIngestFailures: 0,
    serverIngestErrorRate: 0,
    redisCacheStatus: 'disabled',
  },
  deliveryDelay: {
    ...boundaryOverview.deliveryDelay,
    averageMs: 0,
    p50Ms: 0,
    p95Ms: 0,
    p99Ms: 0,
    samples: 0,
  },
};

const boundaryEvent = {
  eventId: 'boundary-event-001',
  recordType: 'diagnostic',
  eventName: 'boundary_event_failed',
  eventVersion: 1,
  deviceId: 'boundary-device-001',
  sessionId: 'boundary-session-001',
  traceId: 'boundary-trace-001',
  occurredAt: '2026-08-27T08:00:00Z',
  feature: 'boundary',
  severity: 'critical',
  appVersion: '1.0.0',
  buildNumber: '100',
  platform: 'windows',
  properties: { source: 'boundary-test' },
};

const boundaryEventsResponse = {
  items: [boundaryEvent],
  total: 101,
  page: 1,
  pageSize: 50,
};

function renderWithProviders(page: ReactNode) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false, retryDelay: 0 } },
  });
  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>{page}</ToastProvider>
    </QueryClientProvider>,
  );
}

function renderDashboard() {
  return renderWithProviders(<TelemetryDashboardPage />);
}

function renderEvents() {
  return renderWithProviders(<TelemetryEventsPage />);
}

describe('Telemetry admin boundary states', () => {
  it('renders degraded metrics and refreshes the all-time view', async () => {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(jsonResponse(boundaryOverview)));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderDashboard();
    await waitFor(() => expect(screen.getByText('864000')).toBeInTheDocument());

    expect(screen.getByText('UNHEALTHY')).toBeInTheDocument();
    expect(screen.getByText('fallback_mysql')).toBeInTheDocument();
    expect(screen.getByText('Redis 探活失败，诊断数据已降级至 MySQL 存储')).toBeInTheDocument();
    expect(screen.getAllByText('1.00s')).toHaveLength(2);
    expect(screen.getAllByText('1.50s')).toHaveLength(2);
    expect(screen.getAllByText('2.00s')).toHaveLength(2);
    expect(screen.getByText('10.0/s')).toBeInTheDocument();
    expect(screen.getByText('not-a-date')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: '全部' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('timeRange=all'),
      expect.anything(),
    ));
    expect(screen.getAllByText('864000')).toHaveLength(2);

    await user.click(screen.getByRole('button', { name: '刷新' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3));
  });

  it('recovers the event explorer, applies filters, pages, resets, and refreshes', async () => {
    const fetchMock = vi.fn().mockImplementation((input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://localhost');
      const page = Number(url.searchParams.get('page') ?? '1');
      return Promise.resolve(jsonResponse({ ...boundaryEventsResponse, page }));
    });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderEvents();
    await waitFor(() => expect(screen.getByText('boundary_event_failed')).toBeInTheDocument());
    expect(screen.getAllByText('CRITICAL')).toHaveLength(2);

    await user.click(screen.getByRole('button', { name: '全部' }));
    const [severitySelect, platformSelect] = screen.getAllByRole('combobox');
    await user.selectOptions(severitySelect, 'critical');
    await user.selectOptions(platformSelect, 'windows');
    await user.type(screen.getByPlaceholderText('按事件名搜索...'), 'boundary');
    await user.type(screen.getByPlaceholderText('按模块搜索 (如 terminal, ssh)...'), 'boundary');
    await user.type(screen.getByPlaceholderText('按设备 ID (deviceId)...'), 'boundary-device');
    await user.type(screen.getByPlaceholderText('按追踪 ID (traceId)...'), 'boundary-trace');
    await user.type(screen.getByPlaceholderText('按错误码 (errorCode)...'), 'BOUNDARY_ERROR');
    await user.click(screen.getByRole('button', { name: '查询' }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('eventName=boundary'),
      expect.anything(),
    ));
    await user.click(screen.getByRole('button', { name: '下一页' }));
    await waitFor(() => expect(screen.getByText(/第 2 页 \/ 共 3 页/)).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '上一页' }));
    await waitFor(() => expect(screen.getByText(/第 1 页 \/ 共 3 页/)).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '重置' }));
    await waitFor(() => expect(fetchMock).toHaveBeenLastCalledWith(
      expect.stringContaining('timeRange=24h'),
      expect.anything(),
    ));
    await user.click(screen.getByRole('button', { name: '刷新' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(6));
  });

  it('shows an event query error and recovers through retry', async () => {
    const fetchMock = vi.fn()
      .mockImplementationOnce(() => Promise.resolve(jsonResponse({
        error: { code: 'unavailable', message: 'event query failed' },
      }, 503)))
      .mockImplementationOnce(() => Promise.resolve(jsonResponse({
        error: { code: 'unavailable', message: 'event query failed' },
      }, 503)))
      .mockImplementation(() => Promise.resolve(jsonResponse(boundaryEventsResponse)));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderEvents();
    await waitFor(() => expect(screen.getByText('event query failed')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '重试' }));
    await waitFor(() => expect(screen.getByText('boundary_event_failed')).toBeInTheDocument());
  });

  it('renders no-data and disabled-cache states, then keeps cached data after refresh failure', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(emptyOverview))
      .mockResolvedValue(jsonResponse({ error: { code: 'unavailable', message: 'overview refresh failed' } }, 503));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderDashboard();
    await waitFor(() => expect(screen.getByText('流水线健康状态')).toBeInTheDocument());

    expect(screen.getByText('DEGRADED')).toBeInTheDocument();
    expect(screen.getByText('disabled')).toBeInTheDocument();
    expect(screen.getByText('Redis 未启用，诊断数据直接查询 MySQL 持久层')).toBeInTheDocument();
    expect(screen.getAllByText('No data').length).toBeGreaterThanOrEqual(8);
    expect(screen.getAllByText('No operations recorded in this time range')).toHaveLength(1);

    await user.click(screen.getByRole('button', { name: '刷新' }));
    await waitFor(() => expect(screen.getByText('最近一次刷新失败，当前展示缓存数据。')).toBeInTheDocument());
    expect(screen.getByText('上报事件总数').closest('article')).toHaveTextContent('0');
  });
});
