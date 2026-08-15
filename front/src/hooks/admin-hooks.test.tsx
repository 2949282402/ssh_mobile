import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { useAdminDevices } from './use-admin-devices';
import { useAdminOverview } from './use-admin-overview';

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

function createWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false },
    },
  });
  return function Wrapper({ children }: { children: ReactNode }) {
    return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
  };
}

describe('admin polling hooks', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('passes React Query cancellation to the overview request and polls every three seconds', async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      server_time: 1_700_000_000,
      uptime_seconds: 21,
      devices: { enrolled: 2, online: 1 },
      relay: { active_transfers: 0 },
      runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
      presence_available: true,
    }));
    vi.stubGlobal('fetch', fetchMock);

    const { result, unmount } = renderHook(() => useAdminOverview(), { wrapper: createWrapper() });
    // React Query batches observer notifications through a setTimeout(0), which
    // the fake timers swallow; advancing by 0 flushes the initial state update.
    // waitFor cannot be used here: it schedules its polling loop via the faked
    // global setTimeout, so it never re-checks. Direct assertions are reliable
    // because advanceTimersByTimeAsync drains both the timer and microtask queues.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(result.current.isSuccess).toBe(true);
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(fetchMock.mock.calls[0][1]).toEqual(expect.objectContaining({ signal: expect.any(AbortSignal) }));

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3000);
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    unmount();
  });

  it('polls the devices request every fifteen seconds', async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ items: [], total: 0, presence_available: true }));
    vi.stubGlobal('fetch', fetchMock);

    const { result, unmount } = renderHook(() => useAdminDevices(), { wrapper: createWrapper() });
    // Same fake-timer flush as the overview polling test above; direct
    // assertions instead of waitFor for the same reason.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(result.current.isSuccess).toBe(true);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(15_000);
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[0][0]).toBe('/api/admin/v1/devices');
    expect(fetchMock.mock.calls[1][1]).toEqual(expect.objectContaining({ signal: expect.any(AbortSignal) }));
    unmount();
  });

  it('aborts a stalled overview fetch when the observing component unmounts', async () => {
    let capturedSignal: AbortSignal | null | undefined;
    const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => {
      capturedSignal = init.signal;
      return new Promise<never>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    const { unmount } = renderHook(() => useAdminOverview(), { wrapper: createWrapper() });
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });
    await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    expect(capturedSignal?.aborted).toBe(false);

    unmount();
    expect(capturedSignal?.aborted).toBe(true);
  });

  it('aborts a stalled devices fetch when the observing component unmounts', async () => {
    let capturedSignal: AbortSignal | null | undefined;
    const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => {
      capturedSignal = init.signal;
      return new Promise<never>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    const { unmount } = renderHook(() => useAdminDevices(), { wrapper: createWrapper() });
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });
    await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    expect(capturedSignal?.aborted).toBe(false);

    unmount();
    expect(capturedSignal?.aborted).toBe(true);
  });
});
