import { z } from 'zod';
import { request } from './client';
import { devicesResponseSchema } from '../schemas/devices';

export const devicesApi = {
  list: () => request('/api/admin/v1/devices', devicesResponseSchema),

  revoke: (deviceId: string) =>
    request(`/api/admin/v1/devices/${encodeURIComponent(deviceId)}/revoke`, z.undefined(), {
      method: 'POST',
    }),
};
