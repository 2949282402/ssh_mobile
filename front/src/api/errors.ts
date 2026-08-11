import { z } from 'zod';

const apiErrorDetailSchema = z.object({
  code: z.string(),
  message: z.string(),
});

const apiErrorSchema = z.object({
  error: apiErrorDetailSchema,
});

export type ApiError = z.infer<typeof apiErrorDetailSchema>;

export class ApiRequestError extends Error {
  readonly status: number;
  readonly payload: ApiError | null;

  constructor(message: string, status: number, payload: ApiError | null = null) {
    super(message);
    this.name = 'ApiRequestError';
    this.status = status;
    this.payload = payload;
  }
}
export function parseApiError(body: unknown): ApiError | null {
  const parsed = apiErrorSchema.safeParse(body);
  return parsed.success ? parsed.data.error : null;
}
