import { describe, expect, it, vi } from 'vitest';
import { telemetryApi } from '../../src/api/telemetry';
import {
  TelemetryFilterSchema,
  TelemetryRecordSchema,
} from '../../src/schemas/telemetry';

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

const baseRecord = {
  eventId: 'release-beta-event',
  recordType: 'analytics' as const,
  eventName: 'ssh.session.started',
  eventVersion: 1,
  deviceId: 'release-device',
  sessionId: 'release-session',
  traceId: 'release-trace',
  occurredAt: '2026-08-28T00:00:00Z',
  feature: 'ssh',
  severity: 'info' as const,
  appVersion: '1.0.0',
  buildNumber: '1',
  platform: 'linux' as const,
  properties: { session_type: 'interactive' },
};

describe('release channel telemetry contract', () => {
  it('accepts release channel on records and filters while retaining legacy records', () => {
    const withChannel = TelemetryRecordSchema.parse({
      ...baseRecord,
      releaseChannel: 'beta',
    });
    expect(withChannel.releaseChannel).toBe('beta');

    const withoutChannel = TelemetryRecordSchema.parse(baseRecord);
    expect(withoutChannel.releaseChannel).toBeUndefined();

    expect(TelemetryFilterSchema.parse({ releaseChannel: 'beta' }).releaseChannel).toBe('beta');
  });

  it('sends release channel as a query parameter and reads it from results', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      items: [{ ...baseRecord, releaseChannel: 'beta' }],
      total: 1,
      page: 1,
      pageSize: 50,
    }));
    vi.stubGlobal('fetch', fetchMock);

    const response = await telemetryApi.getEvents({ releaseChannel: 'beta' });

    expect(response.items[0].releaseChannel).toBe('beta');
    expect(fetchMock.mock.calls[0][0]).toContain('releaseChannel=beta');
  });
});
