import type { ReactNode } from 'react';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { ToastProvider } from '../../src/components/toast';
import { TelemetryDiagnosticsPage } from '../../src/features/telemetry/telemetry-diagnostics-page';

function jsonResponse(body: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    ...init,
  });
}

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

const diagnostics = [
  {
    eventId: 'diag-critical',
    recordType: 'diagnostic',
    eventName: 'critical_event',
    eventVersion: 1,
    occurredAt: '2026-08-28T01:02:03.000Z',
    sessionId: 'session-critical',
    receivedAt: '2026-08-28T01:02:04.000Z',
    severity: 'critical',
    feature: 'relay',
    deviceId: 'device-critical',
    traceId: 'trace-critical',
    platform: 'linux',
    buildNumber: '100',
    appVersion: '1.0.0',
    properties: {},
  },
  {
    eventId: 'diag-warn',
    recordType: 'diagnostic',
    eventName: 'warning_event',
    eventVersion: 1,
    occurredAt: '2026-08-28T02:02:03.000Z',
    sessionId: 'session-warn',
    receivedAt: '2026-08-28T02:02:04.000Z',
    severity: 'warn',
    feature: 'sync',
    deviceId: 'device-warn',
    traceId: 'trace-warn',
    platform: 'linux',
    buildNumber: '100',
    appVersion: '1.0.0',
    properties: { component: 'queue' },
    error: {
      errorCode: 'WARN_QUEUE',
      category: 'network',
      terminalFailure: false,
      message: 'The queue is delayed',
    },
  },
  {
    eventId: 'diag-error',
    recordType: 'diagnostic',
    eventName: 'error_event',
    eventVersion: 1,
    occurredAt: '2026-08-28T03:02:03.000Z',
    sessionId: 'session-error',
    receivedAt: '2026-08-28T03:02:04.000Z',
    severity: 'error',
    feature: 'sync',
    deviceId: 'device-error',
    traceId: 'trace-error',
    platform: 'linux',
    buildNumber: '100',
    appVersion: '1.0.0',
    properties: { retryable: true },
    error: {
      errorCode: 'SYNC_FAILED',
      category: 'network',
      terminalFailure: true,
      message: 'The sync failed',
      stackTrace: 'Error: The sync failed\n    at sync.ts:12:4',
    },
  },
  {
    eventId: 'diag-info',
    recordType: 'diagnostic',
    eventName: 'info_event',
    eventVersion: 1,
    occurredAt: '2026-08-28T04:02:03.000Z',
    sessionId: 'session-info',
    receivedAt: '2026-08-28T04:02:04.000Z',
    severity: 'info',
    feature: 'relay',
    deviceId: 'device-info',
    traceId: 'trace-info',
    platform: 'linux',
    buildNumber: '100',
    appVersion: '1.0.0',
    properties: {},
  },
];

function diagnosticsResponse(page = 1) {
  return {
    source: 'mysql',
    items: diagnostics,
    total: diagnostics.length,
    page,
    pageSize: 2,
    totalPages: 2,
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('TelemetryDiagnosticsPage boundary behavior', () => {
  it('handles source details, filters, pagination, reset, refresh, and expanded log variants', async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn((input: RequestInfo | URL) => {
      const url = new URL(String(input), window.location.origin);
      const page = Number(url.searchParams.get('page') ?? '1');
      return Promise.resolve(jsonResponse(diagnosticsResponse(page)));
    });
    vi.stubGlobal('fetch', fetchMock);

    renderWithProviders(<TelemetryDiagnosticsPage />);

    await waitFor(() => expect(screen.getByText('MYSQL')).toBeInTheDocument());
    expect(screen.getByText('MYSQL')).toHaveClass('badge--neutral');
    expect(screen.getByText('MYSQL')).not.toHaveClass('badge--warning');
    expect(screen.getByText('从 MySQL 权威持久层读取诊断记录')).toBeInTheDocument();
    expect(screen.getByText('critical_event')).toBeInTheDocument();
    expect(screen.getByText('warning_event')).toBeInTheDocument();
    expect(screen.getByText('error_event')).toBeInTheDocument();
    expect(screen.getByText('info_event')).toBeInTheDocument();

    const severity = screen.getByRole('combobox');
    await user.selectOptions(severity, 'critical');
    await user.selectOptions(severity, '');

    const releaseChannelInput = screen.getByPlaceholderText(
      '按发布渠道 (releaseChannel)...',
    );
    expect(releaseChannelInput).toHaveValue('');
    await user.type(releaseChannelInput, 'boundary');
    await user.clear(releaseChannelInput);

    const filterInputs = [
      screen.getByPlaceholderText('按模块搜索 (如 sftp, ssh)...'),
      screen.getByPlaceholderText('按设备 ID (deviceId)...'),
      screen.getByPlaceholderText('按追踪 ID (traceId)...'),
      screen.getByPlaceholderText('按错误码 (errorCode)...'),
    ];
    for (const input of filterInputs) {
      await user.type(input, 'boundary');
      await user.clear(input);
    }
    await user.click(screen.getByRole('button', { name: '查询' }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(screen.getByText(/第 1 页 \/ 共 2 页/)).toBeInTheDocument();

    const warnDetails = screen.getByRole('button', {
      name: '查看日志详情 warning_event',
    });
    await user.click(warnDetails);
    expect(screen.getAllByText(/WARN_QUEUE/)).toHaveLength(2);
    expect(screen.getByText(/"component": "queue"/)).toBeInTheDocument();
    await user.click(warnDetails);

    const errorRow = screen.getByText('error_event').parentElement?.parentElement;
    expect(errorRow).not.toBeNull();
    await user.click(errorRow!);
    expect(screen.getAllByText(/SYNC_FAILED/)).toHaveLength(2);
    expect(screen.getByText(/Error: The sync failed/)).toBeInTheDocument();
    expect(screen.getByText(/"retryable": true/)).toBeInTheDocument();

    // A no-error record with an empty properties object exercises the compact detail variant.
    await user.click(screen.getByRole('button', { name: '查看日志详情 critical_event' }));
    expect(screen.getByText('Event ID / Trace:')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: '下一页' }));
    await waitFor(() => expect(screen.getByText(/第 2 页 \/ 共 2 页/)).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '上一页' }));
    await waitFor(() => expect(screen.getByText(/第 1 页 \/ 共 2 页/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: '重置' }));
    await waitFor(() => expect(screen.getByText(/第 1 页 \/ 共 2 页/)).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '刷新' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(6));
  });

  it('shows the empty state when diagnostics contain no records', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() =>
        Promise.resolve(
          jsonResponse({
            source: 'mysql',
            items: [],
            total: 0,
            page: 1,
            pageSize: 50,
            totalPages: 0,
          }),
        ),
      ),
    );

    renderWithProviders(<TelemetryDiagnosticsPage />);

    await waitFor(() =>
      expect(screen.getByText('未检索到诊断日志')).toBeInTheDocument(),
    );
    expect(screen.getByText('从 MySQL 权威持久层读取诊断记录')).toBeInTheDocument();
  });

  it('recovers from an API error through the retry action', async () => {
    const user = userEvent.setup();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ message: 'temporarily unavailable' }, { status: 503 }))
      .mockResolvedValueOnce(jsonResponse({ message: 'temporarily unavailable' }, { status: 503 }))
      .mockResolvedValueOnce(jsonResponse(diagnosticsResponse()));
    vi.stubGlobal('fetch', fetchMock);

    renderWithProviders(<TelemetryDiagnosticsPage />);

    await waitFor(() =>
      expect(screen.getByText('Relay 请求失败。')).toBeInTheDocument(),
    );
    await user.click(screen.getByRole('button', { name: '重试' }));
    await waitFor(() => expect(screen.getByText('critical_event')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
