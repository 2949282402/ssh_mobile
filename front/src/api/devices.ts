import { z } from 'zod';
import { request } from './client';
import { devicesResponseSchema } from '../schemas/devices';

export const devicesApi = {
  list: (signal?: AbortSignal) => request('/api/admin/v1/devices', devicesResponseSchema, {
    ...(signal ? { signal } : {}),
  }),

  revoke: (deviceId: string, signal?: AbortSignal) =>
    request(`/api/admin/v1/devices/${encodeURIComponent(deviceId)}/revoke`, z.undefined(), {
      method: 'POST',
      ...(signal ? { signal } : {}),
    }),
};
