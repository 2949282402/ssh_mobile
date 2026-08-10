> Last updated: 2026-08-11

# SSH Mobile Relay Admin

This directory contains the standalone React + Vite + TypeScript administration
console for the memory-only SSH Mobile Relay. It owns the browser UI only; the
Go service in `../relay/` owns authentication, device enrollment, relay
sessions, and the v1 WebSocket protocol.

## Development

```sh
npm ci
npm run dev
```

Vite proxies `/api`, `/healthz`, and `/v1` to a local Relay on port `8080`.
Production requests use relative paths through Caddy, so the browser keeps the
HttpOnly administrator session same-origin.

## Validation

```sh
npm run typecheck
npm run lint
npm run test:run
npm run build
```

The Docker image is built by `Dockerfile` and serves the Vite output through
Nginx. Do not store administrator sessions or Enrollment Tokens in browser
storage or URLs.
