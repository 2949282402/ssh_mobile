import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../components/toast';
import { TelemetryDashboardPage } from './telemetry-dashboard-page';

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
  errorFreeSessionRate: 0.982,
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
    serverIngestErrorRate: 0.001,
    redisCacheStatus: 'active',
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

    // Check Pipeline Health
    expect(screen.getByText('3.80 ms')).toBeInTheDocument();
    expect(screen.getByText('0.10%')).toBeInTheDocument();
    expect(screen.getByText('active')).toBeInTheDocument();

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

    expect(screen.getAllByText('无数据')).toHaveLength(3);
    expect(screen.getByText('No operations recorded in this time range')).toBeInTheDocument();
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
