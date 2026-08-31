import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../components/toast';
import { DevicesPage } from './devices-page';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const devices = {
  items: [{
    device_id: 'device-a',
    platform: 'android',
    protocol_version: 1,
    enrolled_at: '2026-08-10T00:00:00Z',
    online: false,
    remote_addr: '',
    public_key_fingerprint: 'SHA256:fingerprint',
  }],
  total: 1,
  presence_available: true,
};

const onlineDevices = {
  ...devices,
  items: [{
    ...devices.items[0],
    online: true,
    remote_addr: '198.51.100.24:43120',
  }],
};

function renderDevices() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <DevicesPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

describe('DevicesPage', () => {
  it('shows the current public IP and port in a dedicated column', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(onlineDevices));
    vi.stubGlobal('fetch', fetchMock);
    renderDevices();

    await waitFor(() => expect(screen.getByText('198.51.100.24:43120')).toBeInTheDocument());
    expect(screen.getByRole('columnheader', { name: '公网 IP / 端口' })).toBeInTheDocument();
    expect(screen.getByTitle('当前公网地址 198.51.100.24:43120')).toBeInTheDocument();
  });

  it('revokes a device after confirmation and refreshes the list', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(devices))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValue(jsonResponse({ items: [], total: 0, presence_available: true }));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderDevices();

    await waitFor(() => expect(screen.getByText('device-a')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '撤销设备 device-a' }));
    expect(screen.getByRole('dialog')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '撤销设备' }));

    await waitFor(() => expect(screen.getByText('设备 device-a 已撤销注册。')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenNthCalledWith(2, '/api/admin/v1/devices/device-a/revoke', expect.objectContaining({
      method: 'POST',
      credentials: 'include',
      signal: expect.any(AbortSignal),
    }));
    await waitFor(() => expect(screen.getByText('还没有注册设备')).toBeInTheDocument());
  });

  it('shows unknown status and disables the online/offline filter when presence is unavailable', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      ...devices,
      presence_available: false,
    }));
    vi.stubGlobal('fetch', fetchMock);
    renderDevices();

    await waitFor(() => expect(screen.getByText('presence 服务异常，设备的在线状态暂不可用。')).toBeInTheDocument());
    // 设备状态显示"未知"；"离线"只应出现在被禁用的筛选按钮上（1 处），而不是设备 badge。
    expect(screen.getByText('未知')).toBeInTheDocument();
    expect(screen.getByText('不可用')).toBeInTheDocument();
    expect(screen.getAllByText('离线')).toHaveLength(1);
    // 在线/离线筛选按钮禁用。
    expect(screen.getByRole('button', { name: '在线' })).toBeDisabled();
    expect(screen.getByRole('button', { name: '离线' })).toBeDisabled();
  });

  it('resets the online/offline filter when presence becomes unavailable', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(devices))
      .mockResolvedValueOnce(jsonResponse({ ...devices, presence_available: false }));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderDevices();

    await waitFor(() => expect(screen.getByText('device-a')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '在线' }));
    expect(screen.getByRole('button', { name: '在线' })).toHaveAttribute('aria-pressed', 'true');

    // 下一次拉取 presence 变为不可用 → 筛选重置为"全部"，不再静默保留旧筛选。
    await user.click(screen.getByRole('button', { name: '刷新设备' }));
    await waitFor(() => expect(screen.getByRole('button', { name: '全部' })).toHaveAttribute('aria-pressed', 'true'));
    expect(screen.getByRole('button', { name: '在线' })).toBeDisabled();
    // device-a（online=false）不再被"在线"筛选过滤掉。
    expect(screen.getByText('device-a')).toBeInTheDocument();
  });

  it('aborts a pending revoke when the page unmounts', async () => {
    let capturedSignal: AbortSignal | null | undefined;
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(devices))
      .mockImplementationOnce((_path: string, init: RequestInit) => {
        capturedSignal = init.signal;
        return new Promise<never>((_resolve, reject) => {
          init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
        });
      });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    const { unmount } = renderDevices();

    await waitFor(() => expect(screen.getByText('device-a')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '撤销设备 device-a' }));
    await user.click(screen.getByRole('button', { name: '撤销设备' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(capturedSignal?.aborted).toBe(false);

    unmount();
    expect(capturedSignal?.aborted).toBe(true);
  });

  it('keeps the device visible and reports revoke failures', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(devices))
      .mockResolvedValueOnce(jsonResponse({ error: { code: 'conflict', message: '设备仍在线' } }, 409));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderDevices();

    await waitFor(() => expect(screen.getByText('device-a')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '撤销设备 device-a' }));
    await user.click(screen.getByRole('button', { name: '撤销设备' }));

    await waitFor(() => expect(screen.getByText('设备仍在线')).toBeInTheDocument());
    expect(screen.getByText('device-a')).toBeInTheDocument();
  });

  it('marks retained devices as stale when a refresh fails', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(devices))
      .mockImplementation(() => Promise.resolve(jsonResponse({
        error: { code: 'unavailable', message: 'device refresh failed' },
      }, 503)));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderDevices();

    await waitFor(() => expect(screen.getByText('device-a')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '刷新设备' }));

    await waitFor(() => {
      expect(screen.getByText(/device refresh failed/)).toBeInTheDocument();
      expect(screen.getByText(/上次成功同步的数据/)).toBeInTheDocument();
    }, { timeout: 3000 });
    expect(screen.getByText('device-a')).toBeInTheDocument();
  });

  it('removes a revoked device locally when the authoritative refresh fails', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(devices))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockImplementation(() => Promise.resolve(jsonResponse({
        error: { code: 'unavailable', message: 'post-revoke refresh failed' },
      }, 503)));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderDevices();

    await waitFor(() => expect(screen.getByText('device-a')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '撤销设备 device-a' }));
    await user.click(screen.getByRole('button', { name: '撤销设备' }));

    await waitFor(() => expect(screen.getByText('还没有注册设备')).toBeInTheDocument());
    await waitFor(() => {
      expect(screen.getByText(/post-revoke refresh failed/)).toBeInTheDocument();
      expect(screen.getByText(/上次成功同步的数据/)).toBeInTheDocument();
    }, { timeout: 3000 });
    expect(screen.queryByText('device-a')).not.toBeInTheDocument();
  });
});
