import { request } from './client';
import { overviewSchema } from '../schemas/overview';

export const overviewApi = {
  get: () => request('/api/admin/v1/overview', overviewSchema),
};
