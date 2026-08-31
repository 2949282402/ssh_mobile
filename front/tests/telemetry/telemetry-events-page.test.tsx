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

const mockEventsResponse = {
  items: [
    {
      eventId: 'evt-001',
      recordType: 'analytics',
      eventName: 'terminal_session_opened',
      eventVersion: 1,
      deviceId: 'device-test-123',
      sessionId: 'sess-abc-456',
      traceId: 'trace-xyz-789',
      occurredAt: '2026-08-27T08:00:00Z',
      receivedAt: '2026-08-27T08:00:01Z',
      feature: 'terminal',
      severity: 'info',
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'android',
      properties: { host: 'example.com', port: 22 },
    },
    {
      eventId: 'evt-002',
      recordType: 'diagnostic',
      eventName: 'ssh_handshake_failed',
      eventVersion: 1,
      deviceId: 'device-test-123',
      sessionId: 'sess-abc-456',
      traceId: 'trace-err-999',
      occurredAt: '2026-08-27T08:05:00Z',
      receivedAt: '2026-08-27T08:05:01Z',
      feature: 'ssh',
      severity: 'error',
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'android',
      properties: { host: 'example.com' },
      error: {
        errorCode: 'ERR_SSH_AUTH_FAILED',
        category: 'auth',
        terminalFailure: true,
        message: 'Invalid key',
        stackTrace: 'Stacktrace line 1\nStacktrace line 2',
      },
    },
  ],
  total: 2,
  page: 1,
  pageSize: 50,
};

function renderEventsPage() {
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
        <TelemetryEventsPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

describe('TelemetryEventsPage', () => {
  it('renders event list and displays event information', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockEventsResponse));
    vi.stubGlobal('fetch', fetchMock);

    renderEventsPage();

    await waitFor(() => expect(screen.getByText('terminal_session_opened')).toBeInTheDocument());
    expect(screen.getByText('ssh_handshake_failed')).toBeInTheDocument();
    expect(screen.getAllByText('device-test-123')).toHaveLength(2);
    expect(screen.getByText(/ERR_SSH_AUTH_FAILED/)).toBeInTheDocument();
    expect(screen.getByText(/共 2 条/)).toBeInTheDocument();
  });

  it('expands event row to show detailed JSON properties and stack trace', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockEventsResponse));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderEventsPage();
    await waitFor(() => expect(screen.getByText('terminal_session_opened')).toBeInTheDocument());

    const detailsBtn = screen.getAllByRole('button', { name: /查看详情/i })[1];
    await user.click(detailsBtn);

    expect(screen.getByText(/Stacktrace line 1/)).toBeInTheDocument();
    expect(screen.getByText(/sess-abc-456/)).toBeInTheDocument();
  });

  it('filters events by event name and severity', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockEventsResponse));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderEventsPage();
    await waitFor(() => expect(screen.getByText('terminal_session_opened')).toBeInTheDocument());

    const eventNameInput = screen.getByPlaceholderText('按事件名搜索...');
    await user.type(eventNameInput, 'ssh_handshake_failed');

    const searchBtn = screen.getByRole('button', { name: '查询' });
    await user.click(searchBtn);

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('eventName=ssh_handshake_failed'),
      expect.anything(),
    ));
  });

  it('handles empty state when no records match filter', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      items: [],
      total: 0,
      page: 1,
      pageSize: 50,
    }));
    vi.stubGlobal('fetch', fetchMock);

    renderEventsPage();
    await waitFor(() => expect(screen.getByText('未检索到埋点事件')).toBeInTheDocument());
  });
});
