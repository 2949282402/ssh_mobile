import { describe, expect, it, vi } from 'vitest';
import { authApi } from './auth';
import { devicesApi } from './devices';
import { overviewApi } from './overview';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

describe('admin API client', () => {
  it('uses same-origin credentials for the overview snapshot', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      server_time: 1_700_000_000,
      uptime_seconds: 21,
      devices: { enrolled: 2, online: 1 },
      relay: { active_transfers: 0 },
      runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
    }));
    vi.stubGlobal('fetch', fetchMock);

    const result = await overviewApi.get();

    expect(result.devices.online).toBe(1);
    expect(fetchMock).toHaveBeenCalledWith('/api/admin/v1/overview', expect.objectContaining({
      credentials: 'include',
      headers: expect.objectContaining({ Accept: 'application/json' }),
    }));
  });

  it('uses a separate devices endpoint and path parameter for revoke', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
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
      }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(devicesApi.list()).resolves.toMatchObject({ total: 1 });
    await expect(devicesApi.revoke('device/a')).resolves.toBeUndefined();
    expect(fetchMock).toHaveBeenLastCalledWith('/api/admin/v1/devices/device%2Fa/revoke', expect.objectContaining({
      method: 'POST',
      credentials: 'include',
    }));
  });

  it('emits an auth expiry signal for an authenticated request that loses its session', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      error: { code: 'unauthorized', message: 'expired' },
    }, 401));
    const unauthorized = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    window.addEventListener('relay:unauthorized', unauthorized);

    await expect(overviewApi.get()).rejects.toMatchObject({ status: 401 });
    expect(unauthorized).toHaveBeenCalledOnce();
    window.removeEventListener('relay:unauthorized', unauthorized);
  });

  it('does not emit the expiry event for a failed login', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      error: { code: 'unauthorized', message: 'invalid credentials' },
    }, 401));
    const unauthorized = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    window.addEventListener('relay:unauthorized', unauthorized);

    await expect(authApi.login('admin', 'wrong-password')).rejects.toMatchObject({ status: 401 });
    expect(unauthorized).not.toHaveBeenCalled();
    window.removeEventListener('relay:unauthorized', unauthorized);
  });
});
