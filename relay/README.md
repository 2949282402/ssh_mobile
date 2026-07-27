> Last updated: 2026-07-26

# SSH Mobile Relay

This service is a memory-only WebSocket relay for SSH Mobile's public E2E SFTP transfer path. It does not persist transfer frames, filenames, metadata, or device registrations. Devices receive stateless, signed credentials after enrollment; restarting the relay drops live sessions but does not expose file contents.

The supplied Compose deployment uses Caddy to terminate HTTPS/WSS and obtain a
public certificate automatically. Set `RELAY_ENROLLMENT_TOKEN` to a one-time
administrator-controlled enrollment secret and `RELAY_CREDENTIAL_KEY` to a
random base64url value containing at least 32 bytes. Never place either value
in source control.

```sh
docker build -t ssh-mobile-relay relay
docker run --rm -p 8080:8080 \
  -e RELAY_ENROLLMENT_TOKEN='replace-me' \
  -e RELAY_CREDENTIAL_KEY='base64url-32-byte-secret' \
  ssh-mobile-relay
```

## Docker Compose deployment

1. Create a public DNS `A` or `AAAA` record for the relay host, then allow TCP
   port 80 and the configured HTTPS port through the host firewall. Keep port
   80 mapped for Caddy's ACME HTTP validation; set `RELAY_HTTPS_PORT` in `.env`
   when clients should use a non-default HTTPS/WSS port.
2. Copy `.env.example` to `.env`; set the real DNS name and secrets. In
   PowerShell, generate a valid base64url credential key with:

   ```powershell
   $bytes = New-Object byte[] 32
   [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
   [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
   ```

3. From this directory, start the service:

   ```sh
   docker compose --env-file .env up --build -d
   docker compose logs -f caddy relay
   ```

The host exposes only Caddy on ports 80/443; the Go relay stays on an internal
Docker network. Caddy persists certificate state only. Do not add a relay data
volume: sessions and relay frames are intentionally memory-only.

`GET /healthz` returns `204`. Device registration is `POST /v1/devices/register`; authenticated devices keep a WSS connection at `/v1/connect`. The relay routes only opaque encrypted payloads and deletes session mappings after expiry or cancellation.
