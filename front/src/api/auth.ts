import { z } from 'zod';
import { request } from './client';
import { AdminApiRoutes } from './routes';
import { authStatusSchema, loginResponseSchema } from '../schemas/auth';

export const authApi = {
  session: (signal?: AbortSignal) => request(AdminApiRoutes.auth.session, authStatusSchema, {
    ...(signal ? { signal } : {}),
  }),

  login: (username: string, password: string) =>
    request(AdminApiRoutes.auth.login, loginResponseSchema, {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    }),

  logout: (signal?: AbortSignal) => request(AdminApiRoutes.auth.logout, z.undefined(), {
    method: 'POST',
    ...(signal ? { signal } : {}),
  }),
};
