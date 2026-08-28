import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../src/components/toast';
import { TelemetryDashboardPage } from '../../src/features/telemetry/telemetry-dashboard-page';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const mockOverviewData = {
  totalEvents: 1250,
  totalDiagnostics: 340,
  recentActiveDevices: 18,
  errorCount: 12,
  criticalErrorCount: 2,
  affectedDevicesCount: 4,
  coreOperationSuccessRate: 0.994,
  businessOperationSuccessRate: 0.994,
  businessOperationSuccesses: 994,
  businessOperationFailures: 6,
  businessOperationDenominator: 1000,
  businessOperationGroups: [],
  errorFreeSessionRate: 0.982,
  errorFreeSessionSuccesses: 98,
  errorFreeSessionDenominator: 100,
  eventsTrend: [
    { timestamp: '2026-08-27T00:00:00Z', value: 450 },
    { timestamp: '2026-08-27T06:00:00Z', value: 800 },
  ],
  errorsTrend: [
    { timestamp: '2026-08-27T00:00:00Z', value: 3 },
    { timestamp: '2026-08-27T06:00:00Z', value: 9 },
  ],
  latency: { p50Ms: 120, p95Ms: 340, p99Ms: 512, samples: 128 },
  pipelineHealth: {
    status: 'healthy',
    serverIngestLatencyMs: 3.8,
    serverIngestLatencyP50Ms: 3,
    serverIngestLatencyP95Ms: 5,
    serverIngestLatencyP99Ms: 7,
    serverIngestLatencySamples: 64,
    serverIngestRequests: 64,
    serverIngestSuccesses: 63,
    serverIngestFailures: 1,
    serverIngestErrorRate: 0.001,
    redisCacheStatus: 'active',
  },
  deliveryDelay: {
    averageMs: 18,
    p50Ms: 12,
    p95Ms: 44,
    p99Ms: 70,
    samples: 120,
    futureTimestampCount: 2,
  },
};

function renderDashboard() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
        retryDelay: 0,
      },
    },
  });
  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <TelemetryDashboardPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

describe('TelemetryDashboardPage', () => {
  it('renders overview KPI metrics and pipeline health', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockOverviewData));
    vi.stubGlobal('fetch', fetchMock);

    renderDashboard();

    // Wait for async fetch data to load
    await waitFor(() => expect(screen.getByText('1250')).toBeInTheDocument());

    // Check KPI metrics
    expect(screen.getByText('1250')).toBeInTheDocument();
    expect(screen.getByText('340')).toBeInTheDocument();
    expect(screen.getByText('18')).toBeInTheDocument();
    expect(screen.getByText('12 (严重: 2)')).toBeInTheDocument();
    expect(screen.getByText('99.4%')).toBeInTheDocument();
    expect(screen.getByText('98.2%')).toBeInTheDocument();
    expect(screen.getByText('业务操作成功率')).toBeInTheDocument();
    expect(screen.getByText('服务端 Ingest P95 延迟')).toBeInTheDocument();
    expect(screen.getByText('5.00 ms')).toBeInTheDocument();
    expect(screen.getByText(/Service\.IngestBatch 从调用到返回的平均耗时/)).toBeInTheDocument();
    expect(screen.getByText(/无论 recordType/)).toBeInTheDocument();
    expect(screen.getByText(/64 次调用作为分母/)).toBeInTheDocument();

    // Check Pipeline Health
    expect(screen.getByText('3.80 ms')).toBeInTheDocument();
    expect(screen.getByText('0.10%')).toBeInTheDocument();
    expect(screen.getByText('active')).toBeInTheDocument();

    // Delivery delay is receivedAt - occurredAt, separate from service ingest.
    expect(screen.getByText('客户端投递延迟')).toBeInTheDocument();
    expect(screen.getByText('18ms')).toBeInTheDocument();
    expect(screen.getByText('未来时间戳样本')).toBeInTheDocument();
    expect(screen.getByText('receivedAt − occurredAt；未来 occurredAt 按 0 ms 计入样本，并单独计数时钟偏差')).toBeInTheDocument();

    // Check latency percentiles and throughput rendering
    expect(screen.getByText('120ms')).toBeInTheDocument();
    expect(screen.getByText('340ms')).toBeInTheDocument();
    expect(screen.getByText('512ms')).toBeInTheDocument();
    expect(screen.getByText('基于 128 次完成操作采样')).toBeInTheDocument();
    // 1250 events over 24h = 0.0145 events/s -> formatted as "0.01/s"
    expect(screen.getByText('0.01/s')).toBeInTheDocument();
  });

  it('renders latency as no-data when samples are zero', async () => {
    const noLatency = {
      ...mockOverviewData,
      latency: { p50Ms: 0, p95Ms: 0, p99Ms: 0, samples: 0 },
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(noLatency));
    vi.stubGlobal('fetch', fetchMock);

    renderDashboard();
    await waitFor(() => expect(screen.getByText('1250')).toBeInTheDocument());

    expect(screen.getAllByText('No data')).toHaveLength(3);
    expect(screen.getByText('No operations recorded in this time range')).toBeInTheDocument();
  });

  it('renders no-data rates when their denominators are zero', async () => {
    const noData = {
      ...mockOverviewData,
      businessOperationSuccessRate: 0,
      businessOperationSuccesses: 0,
      businessOperationFailures: 0,
      businessOperationDenominator: 0,
      errorFreeSessionRate: 0,
      errorFreeSessionSuccesses: 0,
      errorFreeSessionDenominator: 0,
      pipelineHealth: {
        ...mockOverviewData.pipelineHealth,
        serverIngestLatencyMs: 0,
        serverIngestLatencyP50Ms: 0,
        serverIngestLatencyP95Ms: 0,
        serverIngestLatencyP99Ms: 0,
        serverIngestLatencySamples: 0,
        serverIngestRequests: 0,
        serverIngestSuccesses: 0,
        serverIngestFailures: 0,
        serverIngestErrorRate: 0,
      },
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(noData));
    vi.stubGlobal('fetch', fetchMock);

    renderDashboard();
    await waitFor(() => expect(screen.getByText('1250')).toBeInTheDocument());

    expect(screen.queryByText('100.0%')).not.toBeInTheDocument();
    expect(screen.queryByText('0.0%')).not.toBeInTheDocument();
    expect(screen.queryByText('0.00%')).not.toBeInTheDocument();
    expect(screen.getAllByText('No data')).toHaveLength(5);
  });

  it('allows changing time range and refetches metrics', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockOverviewData));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderDashboard();
    await waitFor(() => expect(screen.getByText('1250')).toBeInTheDocument());

    const btn7d = screen.getByRole('button', { name: '7 天' });
    await user.click(btn7d);

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('timeRange=7d'),
      expect.anything(),
    ));
  });

  it('exposes the one-day range with the shared bucket contract', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockOverviewData));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderDashboard();
    await waitFor(() => expect(screen.getByText('1250')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: '1 天' }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('timeRange=1d'),
      expect.anything(),
    ));
  });

  it('shows error state when query fails and retries', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ error: { code: 'server_error', message: '服务异常' } }, 500))
      .mockResolvedValueOnce(jsonResponse({ error: { code: 'server_error', message: '服务异常' } }, 500))
      .mockResolvedValue(jsonResponse(mockOverviewData));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderDashboard();
    await waitFor(() => expect(screen.getByText('服务异常')).toBeInTheDocument());

    const retryBtn = screen.getByRole('button', { name: '重试' });
    await user.click(retryBtn);

    await waitFor(() => expect(screen.getByText('1250')).toBeInTheDocument());
  });
});
