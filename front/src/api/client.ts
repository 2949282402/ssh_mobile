import { z } from 'zod';
import { ApiRequestError, parseApiError } from './errors';

async function parseResponse(response: Response): Promise<unknown> {
  const contentType = response.headers.get('content-type') ?? '';
  if (!contentType.includes('application/json')) {
    return null;
  }

  try {
    return await response.json();
  } catch {
    return null;
  }
}
export async function request<T>(
  path: string,
  schema: z.ZodType<T>,
  init?: RequestInit,
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, {
      ...init,
      credentials: 'include',
      headers: {
        Accept: 'application/json',
        ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
        ...init?.headers,
      },
    });
  } catch {
    throw new ApiRequestError('无法连接 Relay 服务。', 0);
  }

  const body = await parseResponse(response);
  if (!response.ok) {
    const parsedError = parseApiError(body);
    const message = parsedError?.message ?? 'Relay 请求失败。';
    if (response.status === 401 && !path.endsWith('/auth/login')) {
      window.dispatchEvent(new Event('relay:unauthorized'));
    }
    throw new ApiRequestError(message, response.status, parsedError);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  const parsed = schema.safeParse(body);
  if (!parsed.success) {
    throw new ApiRequestError('Relay 返回的数据格式无效。', response.status);
  }
  return parsed.data;
}
