import { request } from './client';
import { enrollmentTokenResponseSchema } from '../schemas/access';

export const accessApi = {
  token: () => request('/api/admin/v1/access/enrollment-token', enrollmentTokenResponseSchema),

  rotateToken: () =>
    request('/api/admin/v1/access/enrollment-token/rotate', enrollmentTokenResponseSchema, {
      method: 'POST',
    }),
};
