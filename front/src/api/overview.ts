import { request } from './client';
import { overviewSchema } from '../schemas/overview';

export const overviewApi = {
  get: (signal?: AbortSignal) => request('/api/admin/v1/overview', overviewSchema, {
    ...(signal ? { signal } : {}),
  }),
};
