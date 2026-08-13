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

/**
 * True when a request was cancelled via an AbortSignal, whether the DOM's
 * fetch rejected with a DOMException('AbortError') or the caller aborted.
 * Used to skip spurious error toasts when a page-owned mutation is cancelled
 * by an unmount.
 */
export function isAbortError(error: unknown): boolean {
  return (
    typeof error === 'object'
    && error !== null
    && 'name' in error
    && (error as { name?: unknown }).name === 'AbortError'
  );
}

export function shouldRetryApiRequest(failureCount: number, error: unknown) {
  if (error instanceof ApiRequestError && error.status === 401) return false;
  return failureCount < 1;
}
