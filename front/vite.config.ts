import { loadEnv } from 'vite';
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const relayApiOrigin = env.RELAY_DEV_API_ORIGIN;
  const devPort = Number(env.FRONT_DEV_PORT);

  return {
    plugins: [react()],
    server: {
      ...(Number.isInteger(devPort) && devPort > 0 ? { port: devPort } : {}),
      ...(relayApiOrigin
        ? {
            proxy: {
              '/api/admin/v1': relayApiOrigin,
              '/healthz': relayApiOrigin,
              '/v1': relayApiOrigin,
            },
          }
        : {}),
    },
    test: {
      environment: 'jsdom',
      globals: true,
      setupFiles: './src/test/setup.ts',
    },
  };
});
