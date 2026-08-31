import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { telemetryApi } from '../api/telemetry';
import { shouldRetryApiRequest } from '../api/errors';
import { queryKeys } from '../api/query-keys';
import type { TelemetryFilter, TelemetrySettings } from '../schemas/telemetry';

export function useTelemetryOverview(filter?: Partial<TelemetryFilter>) {
  return useQuery({
    queryKey: queryKeys.telemetry.overview(filter as Record<string, unknown>),
    queryFn: ({ signal }) => telemetryApi.getOverview(filter, signal),
    refetchInterval: 5000,
    refetchIntervalInBackground: false,
    retry: shouldRetryApiRequest,
  });
}

export function useTelemetryEvents(filter?: Partial<TelemetryFilter>) {
  return useQuery({
    queryKey: queryKeys.telemetry.events(filter as Record<string, unknown>),
    queryFn: ({ signal }) => telemetryApi.getEvents(filter, signal),
    retry: shouldRetryApiRequest,
  });
}

export function useTelemetryDiagnostics(filter?: Partial<TelemetryFilter>) {
  return useQuery({
    queryKey: queryKeys.telemetry.diagnostics(filter as Record<string, unknown>),
    queryFn: ({ signal }) => telemetryApi.getDiagnostics(filter, signal),
    refetchInterval: 5000,
    refetchIntervalInBackground: false,
    retry: shouldRetryApiRequest,
  });
}

export function useTelemetrySettings() {
  return useQuery({
    queryKey: queryKeys.telemetry.settings,
    queryFn: ({ signal }) => telemetryApi.getSettings(signal),
    retry: shouldRetryApiRequest,
  });
}

export function useUpdateTelemetrySettings() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (settings: TelemetrySettings) => telemetryApi.updateSettings(settings),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.telemetry.settings });
    },
  });
}
