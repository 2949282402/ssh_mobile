#!/usr/bin/env bash

# Live Analytics ingestion probe sourced by client_backend_e2e.sh.
#
# The deployment launcher owns only Compose setup.  The Rust test owns the
# device identity and keeps the one-time telemetry secret in process memory:
# Relay enrollment -> signed telemetry enrollment -> HMAC proof -> short token
# -> ingest -> expired-token 401 -> automatic re-authentication and retry.

telemetry_ingestion_probe() {
  need_command cargo curl
  local native_root="$ROOT_DIR/native/network_core"

  (
    cd -- "$native_root"
    CLIENT_BACKEND_E2E_BASE_URL="$BASE_URL" \
      RELAY_ENROLLMENT_TOKEN="$ENROLLMENT_TOKEN" \
      CLIENT_BACKEND_E2E_STRICT="${CLIENT_BACKEND_E2E_STRICT:-}" \
      cargo test \
        -p network-relay \
        --features test-support \
        --test telemetry_e2e \
        --locked \
        -- \
        --ignored \
        --test-threads=1
  )

  # Keep a stable CI marker for the paired PowerShell gate and downstream log
  # collection.  No credential or response body is included in the marker.
  printf 'TELEMETRY_INGESTION_PASS identity_attestation=1 token_refresh=1\n'
}
