import { z } from 'zod';

export const authStatusSchema = z.object({
  authenticated: z.boolean(),
  username: z.string(),
});

export const loginResponseSchema = z.object({
  username: z.string(),
});

export type AuthStatus = z.infer<typeof authStatusSchema>;
