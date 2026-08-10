import { z } from 'zod';

const authStatusSchema = z.object({
  authenticated: z.boolean(),
  username: z.string(),
});

const peerInfoSchema = z.object({
  device_id: z.string(),
  remote_addr: z.string(),
});

const enrolledDeviceSchema = z.object({
  device_id: z.string(),
  public_key: z.string(),
  platform: z.string(),
  protocol_version: z.number(),
  enrolled_at: z.string(),
});

const statsResponseSchema = z.object({
  uptime_seconds: z.number(),
  uptime_formatted: z.string(),
  active_peers: z.number(),
  active_sessions: z.number(),
  allocated_mem_mb: z.number(),
  num_goroutines: z.number(),
  server_time: z.number(),
  enrolled_count: z.number(),
  peers: z.array(peerInfoSchema),
  enrolled_devices: z.array(enrolledDeviceSchema),
});

const enrollmentTokenResponseSchema = z.object({
  enrollment_token: z.string(),
});

const apiErrorSchema = z.object({
  code: z.number().optional(),
  message: z.string().optional(),
  operation: z.string().optional(),
  peer_id: z.string().optional(),
});

export type AuthStatus = z.infer<typeof authStatusSchema>;
export type PeerInfo = z.infer<typeof peerInfoSchema>;
export type EnrolledDevice = z.infer<typeof enrolledDeviceSchema>;
export type StatsResponse = z.infer<typeof statsResponseSchema>;
export type EnrollmentTokenResponse = z.infer<
  typeof enrollmentTokenResponseSchema
>;
export type ApiError = z.infer<typeof apiErrorSchema>;

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

async function request<T>(
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
    const parsedError = apiErrorSchema.safeParse(body);
    const message = parsedError.success
      ? parsedError.data.message ?? 'Relay 请求失败。'
      : 'Relay 请求失败。';
    if (response.status === 401 && !path.endsWith('/login')) {
      window.dispatchEvent(new Event('relay:unauthorized'));
    }
    throw new ApiRequestError(
      message,
      response.status,
      parsedError.success ? parsedError.data : null,
    );
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

export const relayApi = {
  authStatus: () => request('/api/auth-status', authStatusSchema),

  login: (username: string, password: string) =>
    request(
      '/api/login',
      z.object({ username: z.string() }),
      {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      },
    ),

  logout: () =>
    request('/api/logout', z.undefined(), {
      method: 'POST',
    }),

  stats: () => request('/api/stats', statsResponseSchema),

  token: () =>
    request('/api/token', enrollmentTokenResponseSchema),

  rotateToken: () =>
    request('/api/token/rotate', enrollmentTokenResponseSchema, {
      method: 'POST',
    }),

  revokeDevice: (deviceId: string) =>
    request(
      '/api/devices/revoke',
      z.object({ device_id: z.string() }),
      {
        method: 'POST',
        body: JSON.stringify({ device_id: deviceId }),
      },
    ),
};
