import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BrowserRouter } from 'react-router-dom';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { App } from '../../src/app';
import { queryKeys } from '../../src/api/query-keys';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function renderApp() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return {
    queryClient,
    ...render(
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <App />
        </BrowserRouter>
      </QueryClientProvider>,
    ),
  };
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

  it('fails closed when the session recheck after a protected 401 is unavailable', async () => {
    window.history.pushState({}, '', '/overview');
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ authenticated: true, username: 'admin' }))
      .mockResolvedValueOnce(jsonResponse({
        error: { code: 'unauthorized', message: 'session expired' },
      }, 401))
      .mockResolvedValueOnce(jsonResponse({
        error: { code: 'unavailable', message: 'session probe unavailable' },
      }, 503));
    vi.stubGlobal('fetch', fetchMock);
    renderApp();

    await waitFor(() => expect(screen.getByText('登录控制台')).toBeInTheDocument());
    await waitFor(() => expect(screen.getByText('session probe unavailable')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: '退出登录' })).not.toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledTimes(3);
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

  it('clears a connection error after a successful unauthenticated retry', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        error: { code: 'unavailable', message: 'Relay unavailable' },
      }, 503))
      .mockResolvedValueOnce(jsonResponse({ authenticated: false, username: '' }));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderApp();

    await waitFor(() => expect(screen.getByText('Relay unavailable')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '重新检查连接' }));

    await waitFor(() => expect(screen.queryByText('Relay unavailable')).not.toBeInTheDocument());
    expect(screen.queryByRole('button', { name: '重新检查连接' })).not.toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('returns to the login page after an explicit logout', async () => {
    let sessionChecks = 0;
    const fetchMock = vi.fn().mockImplementation((path: string) => {
      if (path.endsWith('/auth/session')) {
        sessionChecks += 1;
        return Promise.resolve(jsonResponse({
          authenticated: sessionChecks === 1,
          username: sessionChecks === 1 ? 'admin' : '',
        }));
      }
      if (path.endsWith('/auth/logout')) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      if (path.endsWith('/overview')) {
        return Promise.resolve(jsonResponse({
          server_time: 1_700_000_000,
          uptime_seconds: 21,
          devices: { enrolled: 0, online: 0 },
          relay: { active_transfers: 0 },
          runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
          presence_available: true,
        }));
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderApp();

    await waitFor(() => expect(screen.getByRole('button', { name: '退出登录' })).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '退出登录' }));

    await waitFor(() => expect(screen.getByText('登录控制台')).toBeInTheDocument());
    expect(sessionChecks).toBe(1);
  });

  it('does not restore an authenticated session from a probe that finishes after logout', async () => {
    window.history.pushState({}, '', '/overview');
    let sessionChecks = 0;
    let lateSessionSignal: AbortSignal | null | undefined;
    let resolveLateSession: ((response: Response) => void) | undefined;
    const fetchMock = vi.fn().mockImplementation((path: string, init: RequestInit) => {
      if (path.endsWith('/auth/session')) {
        sessionChecks += 1;
        if (sessionChecks === 1) {
          return Promise.resolve(jsonResponse({ authenticated: true, username: 'admin' }));
        }
        lateSessionSignal = init.signal;
        return new Promise<Response>((resolve) => {
          resolveLateSession = resolve;
        });
      }
      if (path.endsWith('/auth/logout')) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      if (path.endsWith('/overview')) {
        return Promise.resolve(jsonResponse({
          server_time: 1_700_000_000,
          uptime_seconds: 21,
          devices: { enrolled: 0, online: 0 },
          relay: { active_transfers: 0 },
          runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
          presence_available: true,
        }));
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    const rendered = renderApp();

    const logoutButton = await screen.findByRole('button', { name: '退出登录' });
    const pendingProbe = rendered.queryClient.refetchQueries({ queryKey: queryKeys.auth, exact: true });
    await waitFor(() => expect(sessionChecks).toBe(2));
    await user.click(logoutButton);

    await waitFor(() => expect(screen.getByText('登录控制台')).toBeInTheDocument());
    expect(lateSessionSignal?.aborted).toBe(true);

    await act(async () => {
      resolveLateSession?.(jsonResponse({ authenticated: true, username: 'admin' }));
      await pendingProbe;
    });
    expect(screen.getByText('登录控制台')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '退出登录' })).not.toBeInTheDocument();
  });

  it('constrains keyboard focus while the mobile navigation is open', async () => {
    window.history.pushState({}, '', '/overview');
    const fetchMock = vi.fn().mockImplementation((path: string) => {
      if (path.endsWith('/auth/session')) {
        return Promise.resolve(jsonResponse({ authenticated: true, username: 'admin' }));
      }
      if (path.endsWith('/overview')) {
        return Promise.resolve(jsonResponse({
          server_time: 1_700_000_000,
          uptime_seconds: 21,
          devices: { enrolled: 0, online: 0 },
          relay: { active_transfers: 0 },
          runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
          presence_available: true,
        }));
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    renderApp();

    const openButton = await screen.findByRole('button', { name: '打开导航' });
    expect(openButton).toHaveClass('button', 'button--icon', 'mobile-only');
    await user.click(openButton);
    expect(openButton).toHaveAttribute('aria-expanded', 'true');
    expect(document.querySelector('.content-shell')).toHaveAttribute('inert');
    const closeButton = screen.getByRole('button', { name: '关闭导航' });
    expect(closeButton).toHaveClass('button', 'button--icon', 'mobile-only');
    expect(closeButton).toHaveFocus();

    const brandLink = screen.getByRole('link', { name: /SSH Mobile/ });
    brandLink.focus();
    await user.keyboard('{Shift>}{Tab}{/Shift}');
    expect(screen.getByRole('button', { name: '退出登录' })).toHaveFocus();

    await user.keyboard('{Escape}');
    expect(openButton).toHaveAttribute('aria-expanded', 'false');
    expect(document.querySelector('.content-shell')).not.toHaveAttribute('inert');
    expect(openButton).toHaveFocus();
  });

  it('renders telemetry dashboard when navigating to /telemetry', async () => {
    window.history.pushState({}, '', '/telemetry');
    const fetchMock = vi.fn().mockImplementation((path: string) => {
      if (path.endsWith('/auth/session')) {
        return Promise.resolve(jsonResponse({ authenticated: true, username: 'admin' }));
      }
      if (path.includes('/telemetry/overview')) {
        return Promise.resolve(jsonResponse({
          totalEvents: 100,
          totalDiagnostics: 20,
          recentActiveDevices: 5,
          errorCount: 0,
          criticalErrorCount: 0,
          affectedDevicesCount: 0,
          coreOperationSuccessRate: 1.0,
          businessOperationSuccessRate: 1.0,
          businessOperationSuccesses: 1,
          businessOperationFailures: 0,
          businessOperationDenominator: 1,
          businessOperationGroups: [],
          errorFreeSessionRate: 1.0,
          errorFreeSessionSuccesses: 1,
          errorFreeSessionDenominator: 1,
          eventsTrend: [],
          errorsTrend: [],
          pipelineHealth: {
            status: 'healthy',
            serverIngestLatencyMs: 3.5,
            serverIngestLatencyP50Ms: 3,
            serverIngestLatencyP95Ms: 4,
            serverIngestLatencyP99Ms: 5,
            serverIngestLatencySamples: 1,
            serverIngestRequests: 1,
            serverIngestSuccesses: 1,
            serverIngestFailures: 0,
            serverIngestErrorRate: 0.0,
            redisCacheStatus: 'active',
          },
          deliveryDelay: {
            averageMs: 0,
            p50Ms: 0,
            p95Ms: 0,
            p99Ms: 0,
            samples: 0,
            futureTimestampCount: 0,
          },
        }));
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal('fetch', fetchMock);
    renderApp();

    await waitFor(() => expect(screen.getByRole('heading', { name: '数据埋点概览' })).toBeInTheDocument());
    await waitFor(() => expect(screen.getByText('100')).toBeInTheDocument());
  });

  it('highlights only the exact nav link when navigating to a telemetry subroute', async () => {
    window.history.pushState({}, '', '/telemetry/events');
    const fetchMock = vi.fn().mockImplementation((path: string) => {
      if (path.endsWith('/auth/session')) {
        return Promise.resolve(jsonResponse({ authenticated: true, username: 'admin' }));
      }
      if (path.includes('/telemetry/events')) {
        return Promise.resolve(jsonResponse({ items: [], total: 0, page: 1, pageSize: 50 }));
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal('fetch', fetchMock);
    renderApp();

    await waitFor(() => expect(screen.getByRole('heading', { name: '事件浏览器' })).toBeInTheDocument());

    const telemetryParentLink = screen.getByRole('link', { name: /埋点概览 Telemetry/ });
    const eventsLink = screen.getByRole('link', { name: /事件检索 Events/ });

    expect(eventsLink).toHaveClass('nav-link--active');
    expect(telemetryParentLink).not.toHaveClass('nav-link--active');
  });

  it('clears telemetry queries on logout', async () => {
    window.history.pushState({}, '', '/overview');
    let sessionChecks = 0;
    const fetchMock = vi.fn().mockImplementation((path: string) => {
      if (path.endsWith('/auth/session')) {
        sessionChecks += 1;
        return Promise.resolve(jsonResponse({
          authenticated: sessionChecks === 1,
          username: sessionChecks === 1 ? 'admin' : '',
        }));
      }
      if (path.endsWith('/auth/logout')) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      if (path.endsWith('/overview')) {
        return Promise.resolve(jsonResponse({
          server_time: 1_700_000_000,
          uptime_seconds: 21,
          devices: { enrolled: 0, online: 0 },
          relay: { active_transfers: 0 },
          runtime: { allocated_mem_mb: 12.34, goroutines: 7 },
          presence_available: true,
        }));
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();
    const { queryClient } = renderApp();

    queryClient.setQueryData(['telemetry', 'overview', { timeRange: '24h' }], { totalEvents: 50 });
    expect(queryClient.getQueryData(['telemetry', 'overview', { timeRange: '24h' }])).toBeDefined();

    const logoutButton = await screen.findByRole('button', { name: '退出登录' });
    await user.click(logoutButton);

    await waitFor(() => expect(screen.getByText('登录控制台')).toBeInTheDocument());
    expect(queryClient.getQueryData(['telemetry', 'overview', { timeRange: '24h' }])).toBeUndefined();
  });
});
