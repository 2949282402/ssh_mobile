import { z } from 'zod';

export const enrollmentTokenResponseSchema = z.object({
  enrollment_token: z.string(),
});

export type EnrollmentTokenResponse = z.infer<typeof enrollmentTokenResponseSchema>;
