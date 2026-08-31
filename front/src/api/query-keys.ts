export const queryKeys = {
  auth: ['auth'] as const,
  overview: ['relay', 'overview'] as const,
  devices: ['relay', 'devices'] as const,
  token: ['relay', 'token'] as const,
  telemetry: {
    overview: (filter?: Record<string, unknown>) => ['telemetry', 'overview', filter] as const,
    events: (filter?: Record<string, unknown>) => ['telemetry', 'events', filter] as const,
    diagnostics: (filter?: Record<string, unknown>) => ['telemetry', 'diagnostics', filter] as const,
    settings: ['telemetry', 'settings'] as const,
  },
};
