import { request } from './client';
import { enrollmentTokenResponseSchema } from '../schemas/access';

export const accessApi = {
  token: (signal?: AbortSignal) => request('/api/admin/v1/access/enrollment-token', enrollmentTokenResponseSchema, {
    ...(signal ? { signal } : {}),
  }),

  rotateToken: (signal?: AbortSignal) =>
    request('/api/admin/v1/access/enrollment-token/rotate', enrollmentTokenResponseSchema, {
      method: 'POST',
      ...(signal ? { signal } : {}),
    }),
};
