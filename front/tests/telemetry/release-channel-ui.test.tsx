import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../src/components/toast';
import { TelemetryDashboardPage } from '../../src/features/telemetry/telemetry-dashboard-page';
import { TelemetryDiagnosticsPage } from '../../src/features/telemetry/telemetry-diagnostics-page';
import { TelemetryEventsPage } from '../../src/features/telemetry/telemetry-events-page';

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

function renderWithQueryClient(element: React.ReactElement) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false, retryDelay: 0 },
    },
  });
  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>{element}</ToastProvider>
    </QueryClientProvider>,
  );
}

const record = {
  eventId: 'release-channel-ui-event',
  recordType: 'analytics',
  eventName: 'ssh.session.started',
  eventVersion: 1,
  deviceId: 'release-channel-device',
  sessionId: 'release-channel-session',
  traceId: 'release-channel-trace',
  occurredAt: '2026-08-28T00:00:00Z',
  feature: 'ssh',
  severity: 'info',
  appVersion: '1.0.0',
  buildNumber: '1',
  platform: 'linux',
  releaseChannel: 'beta',
  properties: { session_type: 'interactive' },
};

describe('release channel telemetry UI', () => {
  it('filters the event explorer and renders the channel', async () => {
    const eventsBody = {
      items: [record],
      total: 1,
      page: 1,
      pageSize: 50,
    };
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(jsonResponse(eventsBody)));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderWithQueryClient(<TelemetryEventsPage />);
    await waitFor(() => expect(screen.getByText('ssh.session.started')).toBeInTheDocument());
    expect(screen.getByText('channel: beta')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '查看详情 ssh.session.started' }));
    expect(screen.getByText('Release Channel:')).toBeInTheDocument();

    await user.type(screen.getByPlaceholderText('按发布渠道 (releaseChannel)...'), 'beta');
    await user.click(screen.getByRole('button', { name: '查询' }));
    await waitFor(() => expect(
      fetchMock.mock.calls.some(([url]) => String(url).includes('releaseChannel=beta')),
    ).toBe(true));
  });

  it('filters diagnostic logs by release channel', async () => {
    const diagnosticsBody = {
      items: [{ ...record, recordType: 'diagnostic', releaseChannel: 'internal' }],
      total: 1,
      page: 1,
      pageSize: 20,
      source: 'mysql',
    };
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(jsonResponse(diagnosticsBody)));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderWithQueryClient(<TelemetryDiagnosticsPage />);
    await waitFor(() => expect(screen.getByText('ssh.session.started')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '查看日志详情 ssh.session.started' }));
    expect(screen.getByText('Release Channel:')).toBeInTheDocument();
    await user.type(screen.getByPlaceholderText('按发布渠道 (releaseChannel)...'), 'internal');
    await user.click(screen.getByRole('button', { name: '查询' }));

    await waitFor(() => expect(
      fetchMock.mock.calls.some(([url]) => String(url).includes('releaseChannel=internal')),
    ).toBe(true));
  });

  it('passes the dashboard release channel to the overview query', async () => {
    const overviewBody = {
      totalEvents: 1,
      totalDiagnostics: 0,
      recentActiveDevices: 1,
      errorCount: 0,
      criticalErrorCount: 0,
      affectedDevicesCount: 0,
      coreOperationSuccessRate: 0,
      businessOperationSuccessRate: 0,
      businessOperationSuccesses: 0,
      businessOperationFailures: 0,
      businessOperationDenominator: 0,
      businessOperationGroups: [],
      errorFreeSessionRate: 1,
      errorFreeSessionSuccesses: 1,
      errorFreeSessionDenominator: 1,
      eventsTrend: [],
      errorsTrend: [],
      latency: { p50Ms: 0, p95Ms: 0, p99Ms: 0, samples: 0 },
      pipelineHealth: {
        status: 'healthy',
        serverIngestLatencyMs: 1,
        serverIngestLatencyP50Ms: 1,
        serverIngestLatencyP95Ms: 1,
        serverIngestLatencyP99Ms: 1,
        serverIngestLatencySamples: 1,
        serverIngestRequests: 1,
        serverIngestSuccesses: 1,
        serverIngestFailures: 0,
        serverIngestErrorRate: 0,
        redisCacheStatus: 'active',
      },
      deliveryDelay: {
        averageMs: 1,
        p50Ms: 1,
        p95Ms: 1,
        p99Ms: 1,
        samples: 1,
        futureTimestampCount: 0,
      },
    };
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(jsonResponse(overviewBody)));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderWithQueryClient(<TelemetryDashboardPage />);
    await waitFor(() => expect(screen.getByText('数据埋点概览')).toBeInTheDocument());
    await user.type(await screen.findByLabelText('发布渠道 (releaseChannel)'), 'beta');
    await user.click(screen.getByRole('button', { name: '应用发布渠道筛选' }));
    await waitFor(() => expect(
      fetchMock.mock.calls.some(([url]) => String(url).includes('releaseChannel=beta')),
    ).toBe(true));
  });
});
