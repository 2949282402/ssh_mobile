import { z } from 'zod';
import { request } from './client';
import { AdminApiRoutes } from './routes';
import { devicesResponseSchema } from '../schemas/devices';

export const devicesApi = {
  list: (signal?: AbortSignal) => request(AdminApiRoutes.devices.list, devicesResponseSchema, {
    ...(signal ? { signal } : {}),
  }),

  revoke: (deviceId: string, signal?: AbortSignal) =>
    request(AdminApiRoutes.devices.revoke(deviceId), z.undefined(), {
      method: 'POST',
      ...(signal ? { signal } : {}),
    }),
};
