import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../components/toast';
import { TelemetrySettingsPage } from './telemetry-settings-page';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const mockSettings = {
  policy: {
    uploadEnabled: true,
    batchSizeThreshold: 50,
    timeIntervalSeconds: 60,
    maxBatchSize: 100,
    clientMaxLocalRecords: 10000,
    specialTriggers: [
      'highPriorityError',
      'appBackground',
      'networkRecovered',
      'appForegroundWithBacklog',
    ],
    policyVersion: 1,
  },
  retentionDays: 30,
  retentionMaxRows: 500000,
  retentionTimeEnabled: true,
  retentionRowsEnabled: true,
  redisCacheEnabled: true,
  redisMaxRecords: 1000,
  updatedAt: '2026-08-27T00:00:00Z',
};

function renderSettingsPage() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
        retryDelay: 0,
      },
    },
  });
  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <TelemetrySettingsPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

describe('TelemetrySettingsPage', () => {
  it('renders settings fields from API', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(mockSettings));
    vi.stubGlobal('fetch', fetchMock);

    renderSettingsPage();

    await waitFor(() => expect(screen.getByDisplayValue('50')).toBeInTheDocument());
    expect(screen.getByDisplayValue('50')).toBeInTheDocument(); // batchSizeThreshold
    expect(screen.getByDisplayValue('60')).toBeInTheDocument(); // timeIntervalSeconds
    expect(screen.getByDisplayValue('30')).toBeInTheDocument(); // retentionDays
    expect(screen.getByDisplayValue('500000')).toBeInTheDocument(); // retentionMaxRows
  });

  it('submits updated settings and shows success feedback', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(mockSettings))
      .mockResolvedValueOnce(jsonResponse({ status: 'ok' }))
      .mockResolvedValue(jsonResponse({ ...mockSettings, retentionDays: 45 }));
    vi.stubGlobal('fetch', fetchMock);
    const user = userEvent.setup();

    renderSettingsPage();
    await waitFor(() => expect(screen.getByDisplayValue('30')).toBeInTheDocument());

    const retentionDaysInput = screen.getByDisplayValue('30');
    await user.clear(retentionDaysInput);
    await user.type(retentionDaysInput, '45');

    const saveBtn = screen.getByRole('button', { name: '保存配置' });
    await user.click(saveBtn);

    await waitFor(() => expect(screen.getByText('埋点与保留配置已更新。')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/admin/v1/telemetry/settings',
      expect.objectContaining({
        method: 'PUT',
        body: expect.stringContaining('"retentionDays":45'),
      }),
    );
  });
});
