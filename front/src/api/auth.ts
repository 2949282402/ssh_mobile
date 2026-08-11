import { z } from 'zod';
import { request } from './client';
import { authStatusSchema, loginResponseSchema } from '../schemas/auth';

export const authApi = {
  session: () => request('/api/admin/v1/auth/session', authStatusSchema),

  login: (username: string, password: string) =>
    request('/api/admin/v1/auth/login', loginResponseSchema, {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    }),

  logout: () => request('/api/admin/v1/auth/logout', z.undefined(), { method: 'POST' }),
};
