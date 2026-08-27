// Canonical Admin API route definitions and endpoint path builders.
// Supports runtime/build configuration via import.meta.env.VITE_ADMIN_API_BASE_URL.

export const ADMIN_API_PREFIX = (
  typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_ADMIN_API_BASE_URL
) ? import.meta.env.VITE_ADMIN_API_BASE_URL : '/api/admin/v1';

export const AdminApiRoutes = {
  auth: {
    session: `${ADMIN_API_PREFIX}/auth/session`,
    login: `${ADMIN_API_PREFIX}/auth/login`,
    logout: `${ADMIN_API_PREFIX}/auth/logout`,
  },
  overview: `${ADMIN_API_PREFIX}/overview`,
  devices: {
    list: `${ADMIN_API_PREFIX}/devices`,
    revoke: (deviceId: string) =>
      `${ADMIN_API_PREFIX}/devices/${encodeURIComponent(deviceId)}/revoke`,
  },
  access: {
    token: `${ADMIN_API_PREFIX}/access/enrollment-token`,
    rotateToken: `${ADMIN_API_PREFIX}/access/enrollment-token/rotate`,
  },
  telemetry: {
    overview: `${ADMIN_API_PREFIX}/telemetry/overview`,
    events: `${ADMIN_API_PREFIX}/telemetry/events`,
    diagnostics: `${ADMIN_API_PREFIX}/telemetry/diagnostics`,
    settings: `${ADMIN_API_PREFIX}/telemetry/settings`,
  },
} as const;
