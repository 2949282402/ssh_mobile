import { describe, expect, it, vi } from 'vitest';
import { REQUEST_TIMEOUT_MS, request } from './client';
import { authApi } from './auth';
import { devicesApi } from './devices';
import { overviewApi } from './overview';
import { overviewSchema } from '../schemas/overview';

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
      presence_available: true,
    }));
    vi.stubGlobal('fetch', fetchMock);

    const result = await overviewApi.get();

    expect(result.devices.online).toBe(1);
    expect(result.presence_available).toBe(true);
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
        presence_available: true,
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

  it('does not emit the expiry event while checking the session', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      error: { code: 'unauthorized', message: 'not signed in' },
    }, 401));
    const unauthorized = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    window.addEventListener('relay:unauthorized', unauthorized);

    await expect(authApi.session()).rejects.toMatchObject({ status: 401 });
    expect(unauthorized).not.toHaveBeenCalled();
    window.removeEventListener('relay:unauthorized', unauthorized);
  });

  it('passes an AbortSignal through and preserves caller cancellation', async () => {
    const controller = new AbortController();
    const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => new Promise<never>((_resolve, reject) => {
      init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
    }));
    vi.stubGlobal('fetch', fetchMock);

    const pending = request('/api/admin/v1/overview', overviewSchema, { signal: controller.signal });
    expect(fetchMock).toHaveBeenCalledWith('/api/admin/v1/overview', expect.objectContaining({
      signal: expect.any(AbortSignal),
    }));
    controller.abort();

    await expect(pending).rejects.toMatchObject({ name: 'AbortError' });
  });

  it('rejects a late success response when fetch ignores caller cancellation', async () => {
    const controller = new AbortController();
    let resolveFetch: ((response: Response) => void) | undefined;
    const fetchMock = vi.fn().mockImplementation(() => new Promise<Response>((resolve) => {
      resolveFetch = resolve;
    }));
    vi.stubGlobal('fetch', fetchMock);

    const pending = overviewApi.get(controller.signal);
    controller.abort();
    resolveFetch?.(jsonResponse({
      server_time: 1_700_000_000,
      uptime_seconds: 21,
      devices: { enrolled: 2, online: 1 },
      relay: { active_transfers: 0 },
      runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
      presence_available: true,
    }));

    await expect(pending).rejects.toMatchObject({ name: 'AbortError' });
  });

  it('converts a stalled request into a bounded timeout error', async () => {
    vi.useFakeTimers();
    try {
      const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => new Promise<never>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
      }));
      vi.stubGlobal('fetch', fetchMock);

      const pending = request('/api/admin/v1/overview', overviewSchema);
      // Attach the rejection handler up-front so the timer-driven rejection is
      // observed instead of surfacing as an unhandled rejection mid-advance.
      const assertion = expect(pending).rejects.toMatchObject({
        status: 0,
        message: 'Relay 请求超时，请稍后重试。',
      });
      await vi.advanceTimersByTimeAsync(REQUEST_TIMEOUT_MS);
      await assertion;
    } finally {
      vi.useRealTimers();
    }
  });

  it('clears the timeout after a mutation-style request settles', async () => {
    vi.useFakeTimers();
    try {
      const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
      vi.stubGlobal('fetch', fetchMock);

      await expect(authApi.logout()).resolves.toBeUndefined();
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it('validates an empty success response against the endpoint schema', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(overviewApi.get()).rejects.toMatchObject({
      status: 204,
      message: 'Relay 返回的数据格式无效。',
    });
  });

  it('honors a caller signal that is already aborted before the request starts', async () => {
    const controller = new AbortController();
    controller.abort();
    const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => new Promise<never>((_resolve, reject) => {
      if (init.signal?.aborted) {
        reject(new DOMException('Aborted', 'AbortError'));
      } else {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
      }
    }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(request('/api/admin/v1/overview', overviewSchema, { signal: controller.signal }))
      .rejects.toMatchObject({ name: 'AbortError' });
    expect(fetchMock.mock.calls[0][1]).toEqual(expect.objectContaining({
      signal: expect.any(AbortSignal),
    }));
    expect((fetchMock.mock.calls[0][1] as RequestInit).signal?.aborted).toBe(true);
  });

  it('cleans up the timeout timer and the caller abort listener after caller cancellation', async () => {
    vi.useFakeTimers();
    try {
      const controller = new AbortController();
      const signal = controller.signal;
      const addEventListener = vi.spyOn(signal, 'addEventListener');
      const removeEventListener = vi.spyOn(signal, 'removeEventListener');
      const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => new Promise<never>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
      }));
      vi.stubGlobal('fetch', fetchMock);

      const pending = request('/api/admin/v1/overview', overviewSchema, { signal });
      expect(fetchMock).toHaveBeenCalledOnce();
      expect(vi.getTimerCount()).toBe(1);

      controller.abort();
      await expect(pending).rejects.toMatchObject({ name: 'AbortError' });

      expect(vi.getTimerCount()).toBe(0);
      expect(addEventListener).toHaveBeenCalledWith('abort', expect.any(Function), { once: true });
      expect(removeEventListener).toHaveBeenCalledWith('abort', expect.any(Function));
    } finally {
      vi.useRealTimers();
    }
  });

  it('classifies a timeout that fires before a caller abort as a timeout', async () => {
    vi.useFakeTimers();
    try {
      const controller = new AbortController();
      const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => new Promise<never>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
      }));
      vi.stubGlobal('fetch', fetchMock);

      const pending = request('/api/admin/v1/overview', overviewSchema, { signal: controller.signal });
      const assertion = expect(pending).rejects.toMatchObject({
        status: 0,
        message: 'Relay 请求超时，请稍后重试。',
      });
      await vi.advanceTimersByTimeAsync(REQUEST_TIMEOUT_MS);
      controller.abort();
      await assertion;
    } finally {
      vi.useRealTimers();
    }
  });

  it('classifies a caller abort that fires before the timeout as a cancellation', async () => {
    vi.useFakeTimers();
    try {
      const controller = new AbortController();
      const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => new Promise<never>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
      }));
      vi.stubGlobal('fetch', fetchMock);

      const pending = request('/api/admin/v1/overview', overviewSchema, { signal: controller.signal });
      controller.abort();
      await expect(pending).rejects.toMatchObject({ name: 'AbortError' });

      // The winning caller abort clears the timeout, so advancing past the
      // deadline must not retroactively reclassify the result as a timeout.
      expect(vi.getTimerCount()).toBe(0);
      await vi.advanceTimersByTimeAsync(REQUEST_TIMEOUT_MS);
      await expect(pending).rejects.toMatchObject({ name: 'AbortError' });
    } finally {
      vi.useRealTimers();
    }
  });

  it('rejects a schema mismatch without exposing the response body', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ server_time: 'not-a-number' }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(overviewApi.get()).rejects.toMatchObject({
      status: 200,
      message: 'Relay 返回的数据格式无效。',
    });
  });

  it('parses presence_available and rejects when the relay omits it', async () => {
    const base = {
      server_time: 1_700_000_000,
      uptime_seconds: 21,
      devices: { enrolled: 2, online: 0 },
      relay: { active_transfers: 0 },
      runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
    };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ ...base, presence_available: false }))
      .mockResolvedValueOnce(jsonResponse(base));
    vi.stubGlobal('fetch', fetchMock);

    await expect(overviewApi.get()).resolves.toMatchObject({ presence_available: false });
    // 旧 relay 不返回该字段：schema 收紧后视为数据格式无效，而不是静默当作"全部离线"。
    await expect(overviewApi.get()).rejects.toMatchObject({
      status: 200,
      message: 'Relay 返回的数据格式无效。',
    });
  });
});
