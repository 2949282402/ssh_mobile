import { request } from './client';
import { AdminApiRoutes } from './routes';
import { enrollmentTokenResponseSchema } from '../schemas/access';

export const accessApi = {
  token: (signal?: AbortSignal) => request(AdminApiRoutes.access.token, enrollmentTokenResponseSchema, {
    ...(signal ? { signal } : {}),
  }),

  rotateToken: (signal?: AbortSignal) =>
    request(AdminApiRoutes.access.rotateToken, enrollmentTokenResponseSchema, {
      method: 'POST',
      ...(signal ? { signal } : {}),
    }),
};
