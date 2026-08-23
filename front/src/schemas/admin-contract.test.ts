import { readFileSync } from 'node:fs';
import { z } from 'zod';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { accessApi } from '../api/access';
import { authApi } from '../api/auth';
import { devicesApi } from '../api/devices';
import { overviewApi } from '../api/overview';

const fixturePath = process.env.SSH_MOBILE_ADMIN_CONTRACT_FIXTURE;

const responseSchema = z.object({
  method: z.string(),
  path: z.string(),
  status: z.number().int(),
  content_type: z.string(),
  body: z.unknown(),
});

const fixtureSchema = z.object({
  unauthenticated_session: responseSchema,
  unauthorized_overview: responseSchema,
  login: responseSchema,
  authenticated_session: responseSchema,
  overview: responseSchema,
  devices: responseSchema,
  enrollment_token: responseSchema,
  rotate_enrollment_token: responseSchema,
  revoke_device: responseSchema,
  logout: responseSchema,
  post_logout_session: responseSchema,
});

type ContractResponse = z.infer<typeof responseSchema>;

function replay(response: ContractResponse) {
  return (input: string | URL | Request, init?: RequestInit) => {
    expect(input).toBe(response.path);
    expect((init?.method ?? 'GET').toUpperCase()).toBe(response.method);
    const headers = response.content_type ? { 'Content-Type': response.content_type } : undefined;
    const body = response.body === null ? null : JSON.stringify(response.body);
    return Promise.resolve(new Response(body, { status: response.status, headers }));
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe.runIf(Boolean(fixturePath))('Relay administrator API contract', () => {
  it('accepts responses emitted by the real Go handlers', async () => {
    if (!fixturePath) throw new Error('contract fixture path is required');
    const fixture = fixtureSchema.parse(JSON.parse(readFileSync(fixturePath, 'utf8')));

    const fetchMock = vi.fn()
      .mockImplementationOnce(replay(fixture.unauthenticated_session))
      .mockImplementationOnce(replay(fixture.unauthorized_overview))
      .mockImplementationOnce(replay(fixture.login))
      .mockImplementationOnce(replay(fixture.authenticated_session))
      .mockImplementationOnce(replay(fixture.overview))
      .mockImplementationOnce(replay(fixture.devices))
      .mockImplementationOnce(replay(fixture.enrollment_token))
      .mockImplementationOnce(replay(fixture.rotate_enrollment_token))
      .mockImplementationOnce(replay(fixture.revoke_device))
      .mockImplementationOnce(replay(fixture.logout))
      .mockImplementationOnce(replay(fixture.post_logout_session));
    vi.stubGlobal('fetch', fetchMock);

    await expect(authApi.session()).resolves.toEqual({
      authenticated: false,
      username: '',
    });
    await expect(overviewApi.get()).rejects.toMatchObject({
      status: 401,
      payload: { code: 'unauthorized' },
    });
    await expect(authApi.login('contract-admin', 'runtime-input')).resolves.toEqual({
      username: 'contract-admin',
    });
    await expect(authApi.session()).resolves.toEqual({
      authenticated: true,
      username: 'contract-admin',
    });
    await expect(overviewApi.get()).resolves.toMatchObject({
      devices: { enrolled: 1 },
      relay: { active_transfers: 0 },
    });
    await expect(devicesApi.list()).resolves.toMatchObject({
      total: 1,
      items: [{ device_id: 'contract-device' }],
    });
    await expect(accessApi.token()).resolves.toEqual({
      enrollment_token: '<redacted>',
    });
    await expect(accessApi.rotateToken()).resolves.toEqual({
      enrollment_token: '<redacted>',
    });
    await expect(devicesApi.revoke('contract-device')).resolves.toBeUndefined();
    await expect(authApi.logout()).resolves.toBeUndefined();
    await expect(authApi.session()).resolves.toEqual({
      authenticated: false,
      username: '',
    });
    expect(fetchMock).toHaveBeenCalledTimes(11);
  });
});
