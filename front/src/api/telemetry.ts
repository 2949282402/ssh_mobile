import { z } from 'zod';
import { request } from './client';
import { AdminApiRoutes } from './routes';
import {
  type TelemetryFilter,
  type TelemetrySettings,
  TelemetryOverviewResponseSchema,
  TelemetryEventsListResponseSchema,
  TelemetryDiagnosticsListResponseSchema,
  TelemetrySettingsSchema,
} from '../schemas/telemetry';

function buildQueryString(filter?: Partial<TelemetryFilter>): string {
  if (!filter) return '';
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(filter)) {
    if (value !== undefined && value !== null && value !== '') {
      params.append(key, String(value));
    }
  }
  const str = params.toString();
  return str ? `?${str}` : '';
}

export const telemetryApi = {
  getOverview: (filter?: Partial<TelemetryFilter>, signal?: AbortSignal) => {
    const url = `${AdminApiRoutes.telemetry.overview}${buildQueryString(filter)}`;
    return request(url, TelemetryOverviewResponseSchema, {
      ...(signal ? { signal } : {}),
    });
  },

  getEvents: (filter?: Partial<TelemetryFilter>, signal?: AbortSignal) => {
    const url = `${AdminApiRoutes.telemetry.events}${buildQueryString(filter)}`;
    return request(url, TelemetryEventsListResponseSchema, {
      ...(signal ? { signal } : {}),
    });
  },

  getDiagnostics: (filter?: Partial<TelemetryFilter>, signal?: AbortSignal) => {
    const url = `${AdminApiRoutes.telemetry.diagnostics}${buildQueryString(filter)}`;
    return request(url, TelemetryDiagnosticsListResponseSchema, {
      ...(signal ? { signal } : {}),
    });
  },

  getSettings: (signal?: AbortSignal) => {
    return request(AdminApiRoutes.telemetry.settings, TelemetrySettingsSchema, {
      ...(signal ? { signal } : {}),
    });
  },

  updateSettings: (settings: TelemetrySettings, signal?: AbortSignal) => {
    return request(
      AdminApiRoutes.telemetry.settings,
      z.object({ status: z.string() }),
      {
        method: 'PUT',
        body: JSON.stringify(settings),
        ...(signal ? { signal } : {}),
      },
    );
  },
};
