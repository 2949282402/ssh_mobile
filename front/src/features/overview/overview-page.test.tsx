import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../components/toast';
import { OverviewPage } from './overview-page';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const overview = {
  server_time: 1_700_000_000,
  uptime_seconds: 21,
  devices: { enrolled: 2, online: 1 },
  relay: { active_transfers: 0 },
  runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
  presence_available: true,
};

function renderOverview() {
  // retryDelay 0 keeps the single React Query retry for recoverable errors
  // deterministic instead of racing the default 1s backoff against waitFor.
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, retryDelay: 0 } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <OverviewPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

describe('OverviewPage', () => {
  it('renders the current snapshot after polling data arrives', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(overview));
    vi.stubGlobal('fetch', fetchMock);
    renderOverview();

    await waitFor(() => expect(screen.getByText('1 台设备在线')).toBeInTheDocument());
    // The memory figure appears both in the metric tile and the runtime panel.
    expect(screen.getAllByText('12.34 MB').length).toBeGreaterThan(0);
    expect(screen.getByText('由 Relay 部署配置决定')).toBeInTheDocument();
    expect(fetchMock.mock.calls[0][1]).toEqual(expect.objectContaining({ signal: expect.any(AbortSignal) }));
  });

  it('shows an unknown state instead of offline when presence is unavailable', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      ...overview,
      devices: { enrolled: 2, online: 0 },
      presence_available: false,
    }));
    vi.stubGlobal('fetch', fetchMock);
    renderOverview();

    await waitFor(() => expect(screen.getByText('在线状态暂不可用，无法确认当前在线设备数。')).toBeInTheDocument());
    expect(screen.getByText('在线状态未知')).toBeInTheDocument();
    // online=0 且 presence 不可用时，绝不能把它当作"全部离线"。
    expect(screen.queryByText('当前没有在线设备')).not.toBeInTheDocument();
    expect(screen.queryByText('0 台设备在线')).not.toBeInTheDocument();
  });

  it('shows a recoverable schema error and succeeds after retry', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ invalid: true }))
      .mockResolvedValueOnce(jsonResponse({ invalid: true }))
      .mockResolvedValueOnce(jsonResponse(overview));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderOverview();

    await waitFor(() => expect(screen.getByText('Relay 返回的数据格式无效。')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '重试' }));
    await waitFor(() => expect(screen.getByText('1 台设备在线')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it('marks retained data as stale when a refresh fails', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(overview))
      .mockImplementation(() => Promise.resolve(jsonResponse({
        error: { code: 'unavailable', message: 'overview refresh failed' },
      }, 503)));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderOverview();

    await waitFor(() => expect(screen.getByText('LIVE SNAPSHOT')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '刷新状态' }));

    await waitFor(() => expect(screen.getByText('STALE SNAPSHOT')).toBeInTheDocument());
    expect(screen.getByText(/overview refresh failed.*上次成功同步的数据/)).toBeInTheDocument();
    expect(screen.queryByText('LIVE SNAPSHOT')).not.toBeInTheDocument();
    expect(screen.getByText('1 台设备在线')).toBeInTheDocument();
  });
});
