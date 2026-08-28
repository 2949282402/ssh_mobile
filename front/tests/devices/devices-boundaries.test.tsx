import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../src/components/toast';
import { DevicesPage } from '../../src/features/devices/devices-page';
import type { DevicesResponse } from '../../src/schemas/devices';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const initialDevices: DevicesResponse = {
  items: [
    {
      device_id: 'device-online',
      platform: 'ios',
      protocol_version: 1,
      enrolled_at: '2026-08-10T00:00:00Z',
      online: true,
      remote_addr: '10.0.0.2:22',
      public_key_fingerprint: 'SHA256:online',
    },
    {
      device_id: 'device-offline',
      platform: 'android',
      protocol_version: 1,
      enrolled_at: '2026-08-11T00:00:00Z',
      online: false,
      remote_addr: '',
      public_key_fingerprint: '',
    },
    {
      device_id: 'device-unknown',
      platform: '',
      protocol_version: 1,
      enrolled_at: '2026-08-12T00:00:00Z',
      online: false,
      remote_addr: '',
      public_key_fingerprint: 'SHA256:unknown',
    },
  ],
  total: 3,
  presence_available: true,
};

function renderDevices() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false, retryDelay: 0 } },
  });
  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <DevicesPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('DevicesPage boundary behavior', () => {
  it('searches by id and platform, filters both statuses, and revokes sequentially', async () => {
    const user = userEvent.setup();
    let currentDevices = structuredClone(initialDevices);
    const fetchMock = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'POST') {
        const segments = String(input).split('/');
        const deviceId = segments[segments.length - 2];
        currentDevices = {
          ...currentDevices,
          items: currentDevices.items.filter((device) => device.device_id !== deviceId),
          total: currentDevices.items.filter((device) => device.device_id !== deviceId).length,
        };
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      return Promise.resolve(jsonResponse(currentDevices));
    });
    vi.stubGlobal('fetch', fetchMock);

    renderDevices();
    await waitFor(() => expect(screen.getByText('device-online')).toBeInTheDocument());
    expect(screen.getByText('10.0.0.2:22')).toBeInTheDocument();
    expect(screen.getByText('unknown')).toBeInTheDocument();

    const search = screen.getByPlaceholderText('搜索设备 ID 或平台');
    await user.type(search, 'device-online');
    expect(screen.getByText('device-online')).toBeInTheDocument();
    expect(screen.queryByText('device-offline')).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '清除搜索' }));
    await user.type(search, 'ios');
    expect(screen.getByText('device-online')).toBeInTheDocument();
    expect(screen.queryByText('device-offline')).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '清除搜索' }));

    await user.click(screen.getByRole('button', { name: '离线' }));
    expect(screen.queryByText('device-online')).not.toBeInTheDocument();
    expect(screen.getByText('device-offline')).toBeInTheDocument();
    expect(screen.getByText('device-unknown')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '在线' }));
    expect(screen.getByText('device-online')).toBeInTheDocument();
    expect(screen.queryByText('device-offline')).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '全部' }));

    await user.click(screen.getByRole('button', { name: '撤销设备 device-online' }));
    await user.click(screen.getByRole('button', { name: '撤销设备' }));
    await waitFor(() => expect(screen.queryByText('device-online')).not.toBeInTheDocument());
    expect(screen.getByText('device-offline')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: '撤销设备 device-offline' }));
    await user.click(screen.getByRole('button', { name: '撤销设备' }));
    await waitFor(() => expect(screen.getByText('device-unknown')).toBeInTheDocument());
    expect(screen.queryByText('device-offline')).not.toBeInTheDocument();
    expect(fetchMock.mock.calls.filter(([, init]) => init?.method === 'POST')).toHaveLength(2);
  });

  it('shows the initial list error and recovers from retry', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ error: { code: 'unavailable', message: 'device list unavailable' } }, 503))
      .mockResolvedValueOnce(jsonResponse({ error: { code: 'unavailable', message: 'device list unavailable' } }, 503))
      .mockResolvedValueOnce(jsonResponse(initialDevices));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderDevices();
    await waitFor(() => expect(screen.getByText('device list unavailable')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '重试' }));
    await waitFor(() => expect(screen.getByText('device-online')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
