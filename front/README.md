> Last updated: 2026-08-24

# SSH Mobile Relay Admin

This directory contains the standalone React + Vite + TypeScript administration
console for SSH Mobile Relay. It owns the browser UI only; the Go service in
`../relay/` owns authentication, device enrollment, optional MySQL/Redis state,
Relay sessions, and the v2 control/data WebSocket protocol.

## Development

```sh
cp .env.example .env
npm ci
npm run dev
```

Vite reads `FRONT_DEV_PORT` and `RELAY_DEV_API_ORIGIN` from `.env`, then proxies
`/api/admin/v1`, `/healthz`, and `/v1` to the configured local Relay origin. Production
requests use relative paths through Caddy, so the browser keeps the
HttpOnly administrator session same-origin.

The browser API is versioned under `/api/admin/v1`. Overview and Devices use
separate response DTOs; the Overview endpoint is polled every three seconds,
while the device list refreshes every fifteen seconds. The legacy `/api/*`
dashboard routes are intentionally not supported.

## Validation

```sh
npm run typecheck
npm run lint
npm run test:run
npm run build
```

From the repository root, run `bash scripts/admin_api_contract.sh` to replay
responses emitted by the real Go administrator handlers through the production
Front request client and Zod schemas. The fixture is generated in a private
temporary directory for each run, redacts credentials, and is never committed.

The Docker image is built by `Dockerfile` and serves the Vite output through
Nginx. Do not store administrator sessions or Enrollment Tokens in browser
storage or URLs.
