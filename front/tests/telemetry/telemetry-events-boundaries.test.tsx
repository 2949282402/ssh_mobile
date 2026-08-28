import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../src/components/toast';
import { TelemetryEventsPage } from '../../src/features/telemetry/telemetry-events-page';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const events = [
  {
    eventId: 'event-info',
    recordType: 'analytics',
    eventName: 'event_info',
    eventVersion: 1,
    deviceId: 'device-info',
    sessionId: 'session-info',
    traceId: 'trace-info',
    occurredAt: '2026-08-28T00:00:00Z',
    feature: 'terminal',
    severity: 'info',
    appVersion: '1.0.0',
    buildNumber: '100',
    platform: 'android',
    properties: { host: 'example.test' },
  },
  {
    eventId: 'event-warn',
    recordType: 'diagnostic',
    eventName: 'event_warn',
    eventVersion: 1,
    deviceId: 'device-warn',
    sessionId: 'session-warn',
    traceId: 'trace-warn',
    occurredAt: '2026-08-28T00:01:00Z',
    feature: 'network',
    severity: 'warn',
    appVersion: '1.0.0',
    buildNumber: '100',
    platform: 'ios',
    properties: { retryable: true },
  },
  {
    eventId: 'event-critical',
    recordType: 'diagnostic',
    eventName: 'event_critical',
    eventVersion: 1,
    deviceId: 'device-critical',
    sessionId: 'session-critical',
    traceId: 'trace-critical',
    occurredAt: '2026-08-28T00:02:00Z',
    feature: 'app',
    severity: 'critical',
    appVersion: '1.0.0',
    buildNumber: '100',
    platform: 'windows',
    properties: {},
  },
  {
    eventId: 'event-error-stack',
    recordType: 'diagnostic',
    eventName: 'event_error_stack',
    eventVersion: 1,
    deviceId: 'device-error',
    sessionId: 'session-error',
    traceId: 'trace-error',
    occurredAt: '2026-08-28T00:03:00Z',
    feature: 'ssh',
    severity: 'error',
    appVersion: '1.0.0',
    buildNumber: '100',
    platform: 'linux',
    properties: { command: 'connect' },
    error: {
      errorCode: 'ERR_STACK',
      category: 'ssh',
      terminalFailure: true,
      message: 'handshake failed',
      stackTrace: 'Error: handshake failed\n at connect (client.ts:1:1)',
    },
  },
  {
    eventId: 'event-error-plain',
    recordType: 'diagnostic',
    eventName: 'event_error_plain',
    eventVersion: 1,
    deviceId: 'device-error-plain',
    sessionId: 'session-error-plain',
    traceId: 'trace-error-plain',
    occurredAt: '2026-08-28T00:04:00Z',
    feature: 'network',
    severity: 'error',
    appVersion: '1.0.0',
    buildNumber: '100',
    platform: 'macos',
    properties: {},
    error: {
      errorCode: 'ERR_PLAIN',
      category: 'network',
      terminalFailure: false,
      message: 'temporary network failure',
    },
  },
];

function renderEventsPage() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false, retryDelay: 0 } },
  });
  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <TelemetryEventsPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

describe('TelemetryEventsPage boundary behavior', () => {
  it('covers event tones, detail branches, filters, pagination, reset, and refresh', async () => {
    const fetchMock = vi.fn().mockImplementation((input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://localhost');
      const page = Number(url.searchParams.get('page') ?? '1');
      return Promise.resolve(jsonResponse({ items: events, total: 203, page, pageSize: 50 }));
    });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderEventsPage();
    await waitFor(() => expect(screen.getByText('event_info')).toBeInTheDocument());
    expect(screen.getAllByText('WARN').length).toBeGreaterThanOrEqual(2);
    expect(screen.getAllByText('CRITICAL').length).toBeGreaterThanOrEqual(2);

    // Changing page before entering filters exercises the optional draft values.
    await user.click(screen.getByRole('button', { name: '下一页' }));
    await waitFor(() => expect(screen.getByText(/第 2 页 \/ 共 5 页/)).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '上一页' }));
    await waitFor(() => expect(screen.getByText(/第 1 页 \/ 共 5 页/)).toBeInTheDocument());

    const infoDetails = screen.getByRole('button', { name: '查看详情 event_info' });
    await user.click(infoDetails);
    expect(screen.getByText('Properties Payload:')).toBeInTheDocument();
    await user.click(infoDetails);

    await user.click(screen.getByRole('button', { name: '查看详情 event_error_stack' }));
    expect(screen.getByText(/\(Terminal\)/)).toBeInTheDocument();
    expect(screen.getByText(/Error: handshake failed/)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '查看详情 event_error_plain' }));
    expect(screen.getByText('Category: network')).toBeInTheDocument();
    expect(screen.queryByText(/\(Terminal\)/)).not.toBeInTheDocument();

    const [severitySelect, platformSelect] = screen.getAllByRole('combobox');
    await user.selectOptions(severitySelect, 'warn');
    await user.selectOptions(severitySelect, '');
    await user.selectOptions(platformSelect, 'ios');
    await user.selectOptions(platformSelect, '');
    await user.type(screen.getByPlaceholderText('按事件名搜索...'), 'event');
    await user.type(screen.getByPlaceholderText('按模块搜索 (如 terminal, ssh)...'), 'network');
    await user.type(screen.getByPlaceholderText('按设备 ID (deviceId)...'), 'device');
    await user.type(screen.getByPlaceholderText('按追踪 ID (traceId)...'), 'trace');
    await user.type(screen.getByPlaceholderText('按错误码 (errorCode)...'), 'ERR');
    await user.click(screen.getByRole('button', { name: '全部' }));
    await user.click(screen.getByRole('button', { name: '查询' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('timeRange=all'),
      expect.anything(),
    ));

    await user.click(screen.getByRole('button', { name: '重置' }));
    await waitFor(() => expect(screen.getByText(/第 1 页 \/ 共 5 页/)).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '刷新' }));
    await waitFor(() => expect(fetchMock.mock.calls.length).toBeGreaterThan(5));
  });

  it('shows an empty result when the query has no matching events', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse({
      items: [],
      total: 0,
      page: 1,
      pageSize: 50,
    })));

    renderEventsPage();
    await waitFor(() => expect(screen.getByText('未检索到埋点事件')).toBeInTheDocument());
  });
});
