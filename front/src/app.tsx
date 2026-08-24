import { useEffect } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Navigate, Route, Routes } from 'react-router-dom';
import { authApi } from './api/auth';
import { ApiRequestError } from './api/errors';
import { queryKeys } from './api/query-keys';
import { AppShell } from './layout/app-shell';
import { LoginPage } from './features/auth/login-page';
import { OverviewPage } from './features/overview/overview-page';
import { DevicesPage } from './features/devices/devices-page';
import { AccessPage } from './features/access/access-page';
import { LoadingScreen } from './components/ui';
import { ToastProvider } from './components/toast';

export function App() {
  return (
    <ToastProvider>
      <AuthGate />
    </ToastProvider>
  );
}

function AuthGate() {
  const queryClient = useQueryClient();
  const authQuery = useQuery({
    queryKey: queryKeys.auth,
    queryFn: ({ signal }) => authApi.session(signal),
    retry: false,
    staleTime: 0,
  });

  useEffect(() => {
    const handleUnauthorized = () => {
      void queryClient.cancelQueries({ queryKey: ['relay'] });
      queryClient.removeQueries({ queryKey: ['relay'] });
      queryClient.setQueryData(queryKeys.auth, {
        authenticated: false,
        username: '',
      });
      void authQuery.refetch();
    };
    window.addEventListener('relay:unauthorized', handleUnauthorized);
    return () => {
      window.removeEventListener('relay:unauthorized', handleUnauthorized);
    };
  }, [authQuery.refetch, queryClient]);

  if (authQuery.isPending) {
    return <LoadingScreen label="正在检查 Relay 会话" />;
  }

  if (authQuery.data?.authenticated) {
    return (
      <Routes>
        <Route
          element={<AppShell username={authQuery.data.username} />}
        >
          <Route path="/" element={<Navigate to="/overview" replace />} />
          <Route path="/overview" element={<OverviewPage />} />
          <Route path="/devices" element={<DevicesPage />} />
          <Route path="/access" element={<AccessPage />} />
          <Route path="*" element={<Navigate to="/overview" replace />} />
        </Route>
      </Routes>
    );
  }

  const authError = authQuery.error instanceof ApiRequestError
    ? authQuery.error.message
    : authQuery.error
      ? '暂时无法连接 Relay 服务。'
      : undefined;

  return (
    <LoginPage
      initialError={authError}
      onAuthenticated={() => void authQuery.refetch()}
      onRetry={() => void authQuery.refetch()}
    />
  );
}
