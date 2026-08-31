import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../src/components/toast';
import { TelemetryDiagnosticsPage } from '../../src/features/telemetry/telemetry-diagnostics-page';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const mockDiagnosticsResponse = {
  items: [
    {
      eventId: 'diag-001',
      recordType: 'diagnostic',
      eventName: 'sftp_transfer_interrupted',
      eventVersion: 1,
      deviceId: 'device-diag-001',
      sessionId: 'sess-diag-001',
      traceId: 'trace-diag-001',
      occurredAt: '2026-08-27T08:10:00Z',
      receivedAt: '2026-08-27T08:10:01Z',
      feature: 'sftp',
      severity: 'error',
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'linux',
      properties: { bytesTransferred: 4096 },
      error: {
        errorCode: 'ERR_SFTP_CONNECTION_CLOSED',
        category: 'io',
        terminalFailure: false,
        message: 'Connection unexpectedly closed by remote host',
        stackTrace: 'Error: Connection closed\n at SftpClient.read',
      },
    },
  ],
  total: 1,
  page: 1,
  pageSize: 20,
  source: 'redis_cache',
};

function renderDiagnosticsPage() {
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
        <TelemetryDiagnosticsPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

describe('TelemetryDiagnosticsPage', () => {
  it('renders diagnostic logs and source indicator badge', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockDiagnosticsResponse));
    vi.stubGlobal('fetch', fetchMock);

    renderDiagnosticsPage();

    await waitFor(() => expect(screen.getByText('sftp_transfer_interrupted')).toBeInTheDocument());
    expect(screen.getByText('REDIS CACHE')).toBeInTheDocument();
    expect(screen.getByText(/ERR_SFTP_CONNECTION_CLOSED/)).toBeInTheDocument();
    expect(screen.getByText('device-diag-001')).toBeInTheDocument();
  });

  it('expands diagnostic log to view error stack trace', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockDiagnosticsResponse));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderDiagnosticsPage();
    await waitFor(() => expect(screen.getByText('sftp_transfer_interrupted')).toBeInTheDocument());

    const toggleBtn = screen.getByRole('button', { name: /查看日志详情/i });
    await user.click(toggleBtn);

    expect(screen.getByText(/SftpClient\.read/)).toBeInTheDocument();
  });

  it('filters diagnostic logs by severity and feature', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockDiagnosticsResponse));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderDiagnosticsPage();
    await waitFor(() => expect(screen.getByText('sftp_transfer_interrupted')).toBeInTheDocument());

    const featureInput = screen.getByPlaceholderText('按模块搜索 (如 sftp, ssh)...');
    await user.type(featureInput, 'sftp');

    const searchBtn = screen.getByRole('button', { name: '查询' });
    await user.click(searchBtn);

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('feature=sftp'),
      expect.anything(),
    ));
  });
});
