import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { queryKeys } from '../../api/query-keys';
import { ToastProvider } from '../../components/toast';
import { AccessPage } from './access-page';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function renderAccess(queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
  return {
    queryClient,
    ...render(
      <QueryClientProvider client={queryClient}>
        <ToastProvider>
          <AccessPage />
        </ToastProvider>
      </QueryClientProvider>,
    ),
  };
}

describe('AccessPage', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('does not read the enrollment token until the administrator asks to display it', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ enrollment_token: 'enrollment-secret' }));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderAccess();

    expect(fetchMock).not.toHaveBeenCalled();
    expect(screen.getByText('••••••••')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: '显示' }));
    await waitFor(() => expect(screen.getByText('enrollment-secret')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledWith('/api/admin/v1/access/enrollment-token', expect.objectContaining({
      credentials: 'include',
      signal: expect.any(AbortSignal),
    }));
  });

  it('reads the token for copy without revealing it in the page', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ enrollment_token: 'copy-only-secret' }));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    // user-event replaces navigator.clipboard with its own stub during setup,
    // so the spy must be installed afterwards to survive that swap.
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });
    const setItem = vi.spyOn(Storage.prototype, 'setItem');
    renderAccess();

    await user.click(screen.getByRole('button', { name: '复制 Token' }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith('copy-only-secret'));
    expect(screen.queryByText('copy-only-secret')).not.toBeInTheDocument();
    expect(window.location.search).toBe('');
    expect(setItem).not.toHaveBeenCalled();
  });

  it('removes the sensitive query cache when leaving the page', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ enrollment_token: 'temporary-secret' }));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    const rendered = renderAccess();

    await user.click(screen.getByRole('button', { name: '显示' }));
    await waitFor(() => expect(rendered.queryClient.getQueryData(queryKeys.token)).toEqual({
      enrollment_token: 'temporary-secret',
    }));

    rendered.unmount();
    expect(rendered.queryClient.getQueryData(queryKeys.token)).toBeUndefined();
  });

  it('aborts a pending token read on unmount and blocks a late token from the cache', async () => {
    let capturedSignal: AbortSignal | null | undefined;
    let resolveFetch: ((response: Response) => void) | undefined;
    const fetchMock = vi.fn().mockImplementation((_path: string, init: RequestInit) => {
      capturedSignal = init.signal;
      return new Promise<Response>((resolve) => {
        resolveFetch = resolve;
      });
    });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    const rendered = renderAccess();

    await user.click(screen.getByRole('button', { name: '显示' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    expect(capturedSignal?.aborted).toBe(false);

    // Leaving the page while the token is still pending aborts the request.
    rendered.unmount();
    expect(capturedSignal?.aborted).toBe(true);

    // Even a pathological response that arrives after the page is gone must
    // not write the cleartext token back into the QueryClient.
    await act(async () => {
      resolveFetch?.(jsonResponse({ enrollment_token: 'late-secret' }));
    });
    await waitFor(() => expect(rendered.queryClient.getQueryData(queryKeys.token)).toBeUndefined());
  });

  it('removes the sensitive query cache after its short lifetime', async () => {
    vi.useFakeTimers();
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    queryClient.setQueryData(queryKeys.token, { enrollment_token: 'expiring-secret' });
    const rendered = renderAccess(queryClient);
    expect(rendered.queryClient.getQueryData(queryKeys.token)).toBeDefined();

    await vi.advanceTimersByTimeAsync(30_000);
    expect(rendered.queryClient.getQueryData(queryKeys.token)).toBeUndefined();
    rendered.unmount();
  });

  it('aborts a pending token rotation when the page unmounts', async () => {
    let capturedSignal: AbortSignal | null | undefined;
    const fetchMock = vi.fn().mockImplementationOnce((_path: string, init: RequestInit) => {
      capturedSignal = init.signal;
      return new Promise<never>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
      });
    });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    const rendered = renderAccess();

    await user.click(screen.getByRole('button', { name: '轮换 Token' }));
    await user.click(screen.getByRole('button', { name: '重新生成 Token' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    expect(capturedSignal?.aborted).toBe(false);

    rendered.unmount();
    expect(capturedSignal?.aborted).toBe(true);
  });

  it('rotates the token only after explicit confirmation', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ enrollment_token: 'rotated-secret' }));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderAccess();

    await user.click(screen.getByRole('button', { name: '轮换 Token' }));
    expect(screen.getByRole('dialog')).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalled();

    await user.click(screen.getByRole('button', { name: '重新生成 Token' }));
    await waitFor(() => expect(screen.getByText('rotated-secret')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledWith('/api/admin/v1/access/enrollment-token/rotate', expect.objectContaining({
      method: 'POST',
      credentials: 'include',
    }));
  });
});
