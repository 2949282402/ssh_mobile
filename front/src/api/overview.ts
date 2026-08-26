import { request } from './client';
import { AdminApiRoutes } from './routes';
import { overviewSchema } from '../schemas/overview';

export const overviewApi = {
  get: (signal?: AbortSignal) => request(AdminApiRoutes.overview, overviewSchema, {
    ...(signal ? { signal } : {}),
  }),
};
