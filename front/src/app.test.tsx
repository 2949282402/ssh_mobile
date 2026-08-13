import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { App } from './app';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function renderApp() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>,
  );
}

describe('AuthGate', () => {
  afterEach(() => {
    window.history.pushState({}, '', '/');
  });

  it('returns to the login page when an authenticated request receives 401', async () => {
    window.history.pushState({}, '', '/overview');
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ authenticated: true, username: 'admin' }))
      .mockResolvedValueOnce(jsonResponse({
        error: { code: 'unauthorized', message: 'session expired' },
      }, 401))
      .mockResolvedValueOnce(jsonResponse({ authenticated: false, username: '' }));
    vi.stubGlobal('fetch', fetchMock);
    const setItem = vi.spyOn(Storage.prototype, 'setItem');
    renderApp();

    await waitFor(() => expect(screen.getByText('登录控制台')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(setItem).not.toHaveBeenCalled();
    expect(window.location.search).toBe('');
    expect(fetchMock.mock.calls[0][1]).toEqual(expect.objectContaining({ signal: expect.any(AbortSignal) }));
  });

  it('does not start an unauthorized refresh loop for an unauthenticated session probe', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      error: { code: 'unauthorized', message: 'not signed in' },
    }, 401));
    vi.stubGlobal('fetch', fetchMock);
    renderApp();

    await waitFor(() => expect(screen.getByText('登录控制台')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledOnce();
  });
});
