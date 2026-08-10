import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../components/toast';
import { LoginPage } from './login-page';

function renderLogin(onAuthenticated = vi.fn()) {
  const queryClient = new QueryClient({ defaultOptions: { mutations: { retry: false } } });
  return {
    onAuthenticated,
    ...render(
      <QueryClientProvider client={queryClient}>
        <ToastProvider>
          <LoginPage onAuthenticated={onAuthenticated} onRetry={vi.fn()} />
        </ToastProvider>
      </QueryClientProvider>,
    ),
  };
}

describe('LoginPage', () => {
  it('submits credentials without exposing them in the page URL', async () => {
    const user = userEvent.setup();
    const onAuthenticated = vi.fn();
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ username: 'admin' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));
    vi.stubGlobal('fetch', fetchMock);
    renderLogin(onAuthenticated);

    await user.type(screen.getByLabelText('管理员账号'), 'admin');
    await user.type(screen.getByLabelText('管理员密码'), 'password');
    await user.click(screen.getByRole('button', { name: /进入 Relay 控制台/ }));

    expect(fetchMock).toHaveBeenCalledWith('/api/login', expect.objectContaining({
      method: 'POST',
      body: JSON.stringify({ username: 'admin', password: 'password' }),
    }));
    expect(window.location.search).toBe('');
    expect(onAuthenticated).toHaveBeenCalledOnce();
  });
});
