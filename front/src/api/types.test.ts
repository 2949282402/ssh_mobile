import { describe, expect, it, vi } from 'vitest';
import { relayApi } from './types';

const statsPayload = {
  uptime_seconds: 21,
  uptime_formatted: '00h 00m 21s',
  active_peers: 1,
  active_sessions: 0,
  allocated_mem_mb: 12.34,
  num_goroutines: 7,
  server_time: 1_700_000_000,
  enrolled_count: 2,
  peers: [{ device_id: 'device-a', remote_addr: '10.0.0.2:42000' }],
  enrolled_devices: [{
    device_id: 'device-a',
    public_key: 'public-key',
    platform: 'android',
    protocol_version: 1,
    enrolled_at: '2026-08-10T00:00:00Z',
  }],
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

describe('relayApi', () => {
  it('uses same-origin credentials for the stats snapshot', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(statsPayload));
    vi.stubGlobal('fetch', fetchMock);

    const result = await relayApi.stats();

    expect(result.active_peers).toBe(1);
    expect(fetchMock).toHaveBeenCalledWith('/api/stats', expect.objectContaining({
      credentials: 'include',
      headers: expect.objectContaining({ Accept: 'application/json' }),
    }));
  });

  it('keeps the enrollment token on its dedicated endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ enrollment_token: 'secret-token' }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(relayApi.token()).resolves.toEqual({ enrollment_token: 'secret-token' });
    expect(fetchMock).toHaveBeenCalledWith('/api/token', expect.objectContaining({ credentials: 'include' }));
  });

  it('emits an auth expiry signal for an authenticated request that loses its session', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ message: 'expired' }, 401));
    const unauthorized = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    window.addEventListener('relay:unauthorized', unauthorized);

    await expect(relayApi.stats()).rejects.toMatchObject({ status: 401 });
    expect(unauthorized).toHaveBeenCalledOnce();
    window.removeEventListener('relay:unauthorized', unauthorized);
  });
});
