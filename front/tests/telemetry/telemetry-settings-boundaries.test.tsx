import type { ReactNode } from 'react';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { ToastProvider } from '../../src/components/toast';
import { TelemetrySettingsPage } from '../../src/features/telemetry/telemetry-settings-page';
import type { TelemetrySettings } from '../../src/schemas/telemetry';

function jsonResponse(body: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    ...init,
  });
}

function renderWithProviders(page: ReactNode) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false, retryDelay: 0 } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>{page}</ToastProvider>
    </QueryClientProvider>,
  );
}

const disabledSettings = {
  policy: {
    uploadEnabled: false,
    batchSizeThreshold: 50,
    timeIntervalSeconds: 60,
    maxBatchSize: 100,
    clientMaxLocalRecords: 10000,
    specialTriggers: [],
    policyVersion: 7,
  },
  retentionDays: 30,
  retentionMaxRows: 500000,
  retentionTimeEnabled: false,
  retentionRowsEnabled: false,
  redisCacheEnabled: false,
  redisMaxRecords: 1000,
  updatedAt: '2026-08-28T00:00:00Z',
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('TelemetrySettingsPage boundary behavior', () => {
  it('edits every control, sanitizes lower and upper limits, resets defaults, and refreshes', async () => {
    const user = userEvent.setup();
    let currentSettings: TelemetrySettings = structuredClone(disabledSettings);
    const fetchMock = vi.fn((_: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'PUT') {
        currentSettings = JSON.parse(String(init.body));
        return Promise.resolve(jsonResponse({ status: 'ok' }));
      }
      return Promise.resolve(jsonResponse(currentSettings));
    });
    vi.stubGlobal('fetch', fetchMock);

    renderWithProviders(<TelemetrySettingsPage />);

    await waitFor(() => expect(screen.getByText('DISABLED')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: '重新拉取' })).toBeInTheDocument();

    const checkboxes = screen.getAllByRole('checkbox');
    expect(checkboxes).toHaveLength(8);
    expect(checkboxes[0]).not.toBeChecked();
    expect(checkboxes[5]).not.toBeChecked();
    expect(screen.getAllByRole('spinbutton')[4]).toBeDisabled();

    await user.click(checkboxes[0]);
    await user.click(checkboxes[1]);
    await user.click(checkboxes[1]);
    await user.click(checkboxes[5]);
    await user.click(checkboxes[6]);
    await user.click(checkboxes[7]);

    const spinbuttons = screen.getAllByRole('spinbutton');
    const lowerValues = ['0', '0', '0', '0', '0', '0', '0'];
    for (const [index, value] of lowerValues.entries()) {
      await user.clear(spinbuttons[index]);
      await user.type(spinbuttons[index], value);
    }

    fireEvent.submit(screen.getByRole('button', { name: '保存配置' }).closest('form')!);
    await waitFor(() => expect(screen.getByText('埋点与保留配置已更新。')).toBeInTheDocument());

    const putCalls = fetchMock.mock.calls.filter(([, init]) => init?.method === 'PUT');
    expect(putCalls).toHaveLength(1);
    const lowerBody = JSON.parse(String(putCalls[0][1]?.body));
    expect(lowerBody.policy).toMatchObject({
      batchSizeThreshold: 50,
      timeIntervalSeconds: 60,
      maxBatchSize: 100,
      clientMaxLocalRecords: 10000,
    });
    expect(lowerBody).toMatchObject({
      retentionDays: 30,
      retentionMaxRows: 500000,
      redisMaxRecords: 1000,
    });

    const upperValues = ['1001', '3601', '1001', '1000001', '3651', '100000001', '10001'];
    const refreshedSpinbuttons = screen.getAllByRole('spinbutton');
    for (const [index, value] of upperValues.entries()) {
      await user.clear(refreshedSpinbuttons[index]);
      await user.type(refreshedSpinbuttons[index], value);
    }
    fireEvent.submit(screen.getByRole('button', { name: '保存配置' }).closest('form')!);
    await waitFor(() => expect(fetchMock.mock.calls.filter(([, init]) => init?.method === 'PUT')).toHaveLength(2));

    const upperCalls = fetchMock.mock.calls.filter(([, init]) => init?.method === 'PUT');
    const upperBody = JSON.parse(String(upperCalls[1][1]?.body));
    expect(upperBody.policy).toMatchObject({
      batchSizeThreshold: 1000,
      timeIntervalSeconds: 3600,
      maxBatchSize: 1000,
      clientMaxLocalRecords: 1000000,
    });
    expect(upperBody).toMatchObject({
      retentionDays: 3650,
      retentionMaxRows: 100000000,
      redisMaxRecords: 10000,
    });

    await user.click(screen.getByRole('button', { name: '恢复默认推荐配置' }));
    expect(screen.getByText(/ACTIVE \(v10\)/)).toBeInTheDocument();
    expect(screen.getByDisplayValue('50')).toBeInTheDocument();
    expect(screen.getByDisplayValue('30')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: '重新拉取' }));
    await waitFor(() => expect(fetchMock.mock.calls.filter(([, init]) => !init?.method)).toHaveLength(4));
    expect(screen.getByText(/ACTIVE \(v10\)/)).toBeInTheDocument();
  });

  it('recovers from a settings API failure through retry', async () => {
    const user = userEvent.setup();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        jsonResponse(
          { error: { code: 'TEMPORARY', message: '策略服务暂不可用' } },
          { status: 503 },
        ),
      )
      .mockResolvedValueOnce(
        jsonResponse(
          { error: { code: 'TEMPORARY', message: '策略服务暂不可用' } },
          { status: 503 },
        ),
      )
      .mockResolvedValueOnce(jsonResponse(disabledSettings));
    vi.stubGlobal('fetch', fetchMock);

    renderWithProviders(<TelemetrySettingsPage />);

    await waitFor(() => expect(screen.getByText('策略服务暂不可用')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: '重试' }));
    await waitFor(() => expect(screen.getByText('DISABLED')).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it('shows the API error when saving settings fails', async () => {
    const user = userEvent.setup();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(disabledSettings))
      .mockResolvedValueOnce(
        jsonResponse(
          { error: { code: 'REJECTED', message: '策略参数被拒绝' } },
          { status: 400 },
        ),
      );
    vi.stubGlobal('fetch', fetchMock);

    renderWithProviders(<TelemetrySettingsPage />);
    await waitFor(() => expect(screen.getByText('DISABLED')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: '保存配置' }));
    await waitFor(() => expect(screen.getByText('策略参数被拒绝')).toBeInTheDocument());
  });
});
