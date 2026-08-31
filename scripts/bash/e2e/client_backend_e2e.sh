#!/usr/bin/env bash

# Cross-process client → Caddy → Go Relay E2E entry point.
#
# The default path starts an isolated memory-mode Compose project with a
# temporary .env outside the repository.  A caller may provide
# CLIENT_BACKEND_E2E_BASE_URL and RELAY_ENROLLMENT_TOKEN to reuse an already
# running test deployment; no credentials are written to relay/.env or logs.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
MODE="${1:-smoke}"
case "$MODE" in
  smoke|strict) ;;
  *)
    echo "Usage: bash scripts/bash/e2e/client_backend_e2e.sh [smoke|strict]" >&2
    exit 64
    ;;
esac

TMP_ROOT=""
COMPOSE_STARTED=0
PROJECT_NAME=""
ENV_FILE=""
BASE_URL="${CLIENT_BACKEND_E2E_BASE_URL:-}"
ENROLLMENT_TOKEN="${RELAY_ENROLLMENT_TOKEN:-}"
STORAGE_MODE="${CLIENT_BACKEND_E2E_STORAGE:-memory}"
COMPOSE_PROFILE_ARGS=()
ADMIN_USER="${CLIENT_BACKEND_E2E_ADMIN_USER:-}"
ADMIN_PASSWORD="${CLIENT_BACKEND_E2E_ADMIN_PASSWORD:-}"
RUST_E2E_PID=""
CURL_TLS_ARGS=()
if [[ -n "${CLIENT_BACKEND_E2E_CA_FILE:-}" ]]; then
  CURL_TLS_ARGS=(--cacert "$CLIENT_BACKEND_E2E_CA_FILE")
fi

# shellcheck source=client_backend_telemetry.sh
source "$SCRIPT_DIR/client_backend_telemetry.sh"

case "$STORAGE_MODE" in
  # Analytics storage is part of every E2E deployment. The Relay storage
  # profile is harmless in memory mode and keeps admin-api dependencies active.
  memory|mysql) COMPOSE_PROFILE_ARGS=(--profile storage) ;;
  *)
    echo "CLIENT_BACKEND_E2E_STORAGE must be memory or mysql: $STORAGE_MODE" >&2
    exit 64
    ;;
esac

compose() {
  docker compose --project-name "$PROJECT_NAME" --env-file "$ENV_FILE" \
    --file "$ROOT_DIR/compose.yaml" "${COMPOSE_PROFILE_ARGS[@]}" "$@"
}

cleanup() {
  local status=$?
  if [[ -n "$RUST_E2E_PID" ]]; then
    kill "$RUST_E2E_PID" 2>/dev/null || true
    wait "$RUST_E2E_PID" 2>/dev/null || true
    RUST_E2E_PID=""
  fi
  if ((COMPOSE_STARTED)); then
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf -- "$TMP_ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

need_command() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "ENVIRONMENT GAP: required command is unavailable: $command_name" >&2
      exit 125
    }
  done
}

random_hex() {
  local bytes="$1"
  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

random_b64url() {
  local bytes="$1"
  openssl rand -base64 "$bytes" | tr '+/' '-_' | tr -d '=\n'
}

find_free_port() {
  python3 - <<'PY'
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(('127.0.0.1', 0))
print(sock.getsockname()[1])
sock.close()
PY
}

network_overlaps_existing() {
  local candidate existing_subnets
  candidate="$1"
  # Docker rejects a new network when its subnet overlaps any existing
  # network, including a broader /16 or /8. Compare CIDRs rather than only
  # matching identical strings so the E2E deployment can avoid runner-level
  # networks as well as networks left by another job.
  existing_subnets="$(
    docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' \
      $(docker network ls --quiet) 2>/dev/null || true
  )"
  python3 - "$candidate" "$existing_subnets" <<'PY'
import ipaddress
import sys

candidate = ipaddress.ip_network(sys.argv[1], strict=False)
for value in sys.argv[2].splitlines():
    value = value.strip()
    if not value:
        continue
    try:
        existing = ipaddress.ip_network(value, strict=False)
    except ValueError:
        continue
    if candidate.overlaps(existing):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

wait_health() {
  local attempt status
  for attempt in $(seq 1 90); do
    status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 3 \
      --output /dev/null --write-out '%{http_code}' "$BASE_URL/healthz" || true)"
    if [[ "$status" == 204 ]]; then
      return 0
    fi
    sleep 1
  done
  echo "Relay health probe did not become ready: $BASE_URL/healthz" >&2
  return 1
}

assert_relay_routes() {
  local route status headers body content_type
  for route in /v2/control /v2/relay/00000000000000000000000000000000; do
    headers="$TMP_ROOT/headers"
    body="$TMP_ROOT/body"
    : > "$headers"
    : > "$body"
    status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 5 \
      --header 'Accept: application/json' --dump-header "$headers" \
      --output "$body" --write-out '%{http_code}' "$BASE_URL$route" || true)"
    content_type="$(awk 'BEGIN {IGNORECASE=1} /^Content-Type:/ {print $2}' "$headers" | tail -n 1 | tr -d '\r')"
    if [[ "$status" == 200 && "$content_type" == text/html* ]]; then
      echo "Relay route regression: $route returned Front HTML" >&2
      return 1
    fi
    if [[ "$status" != 401 ]]; then
      echo "Relay route regression: $route returned HTTP $status (expected unauthenticated 401)" >&2
      return 1
    fi
    # An unauthenticated request must be JSON Relay auth output, not a SPA.
    if [[ "$content_type" != application/json* ]]; then
      echo "Relay route regression: $route returned Content-Type $content_type" >&2
      return 1
    fi
  done
}

start_compose() {
  need_command docker curl python3 openssl od tr awk tail
  docker info >/dev/null 2>&1 || {
    echo "ENVIRONMENT GAP: Docker daemon is unavailable" >&2
    exit 125
  }
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/client-backend-e2e.XXXXXX")"
  chmod 700 "$TMP_ROOT"
  PROJECT_NAME="ssh-mobile-client-backend-${BASHPID}"
  ENV_FILE="$TMP_ROOT/relay.env"
  local http_port https_port credential_key network_second network_third
  local network_subnet caddy_ip network_attempt
  local mysql_root_password mysql_user mysql_password redis_password relay_storage_mode relay_database_url relay_redis_url
  local analytics_mysql_password analytics_mysql_root_password analytics_redis_password telemetry_auth_secret
  http_port="$(find_free_port)"
  https_port="$(find_free_port)"
  ENROLLMENT_TOKEN="$(random_hex 24)"
  credential_key="$(random_b64url 32)"
  local admin_auth_key internal_token
  admin_auth_key="$(random_b64url 32)"
  internal_token="$(random_hex 24)"
  ADMIN_USER=e2e-admin
  ADMIN_PASSWORD="$(random_hex 24)"
  mysql_root_password="$(random_hex 24)"
  mysql_user="e2e_relay"
  mysql_password="$(random_hex 24)"
  redis_password="$(random_hex 24)"
  analytics_mysql_password="$(random_hex 24)"
  analytics_mysql_root_password="$(random_hex 24)"
  analytics_redis_password="$(random_hex 24)"
  telemetry_auth_secret="$(random_hex 24)"
  BASE_URL="http://127.0.0.1:${http_port}"
  # Keep test networks in a high, private 10/8 range. The candidate is still
  # checked against every Docker CIDR because runner images may customize
  # their address pools or retain broader networks than Docker's defaults.
  for network_attempt in $(seq 1 128); do
    network_second=$((240 + $(od -An -N1 -tu1 /dev/urandom) % 16))
    network_third=$(( $(od -An -N1 -tu1 /dev/urandom) ))
    network_subnet="10.${network_second}.${network_third}.0/24"
    if ! network_overlaps_existing "$network_subnet"; then
      break
    fi
    if ((network_attempt == 128)); then
      echo "ENVIRONMENT GAP: no isolated Docker subnet is available" >&2
      return 125
    fi
  done
  caddy_ip="10.${network_second}.${network_third}.10"

  # Keep this file private and outside the repository.  Values are passed to
  # child processes through their environment, never echoed by this script.
  umask 077
  local credential_ttl="${CLIENT_BACKEND_E2E_CREDENTIAL_TTL:-24h}"
  if [[ "$MODE" == strict && -z "${CLIENT_BACKEND_E2E_CREDENTIAL_TTL:-}" ]]; then
    credential_ttl=45s
  fi
  # Caddy listens on its container port 80; the host port belongs only in
  # the advertised URL. Including the random host port in the Caddy site
  # address would make Caddy listen on that port inside the container and
  # cause Docker's 80→host mapping to reset connections.
  relay_storage_mode=memory
  relay_database_url=
  relay_redis_url=
  if [[ "$STORAGE_MODE" == mysql ]]; then
    relay_storage_mode=mysql
    relay_database_url="${mysql_user}:${mysql_password}@tcp(mysql:3306)/relay?parseTime=true&loc=UTC"
    relay_redis_url='redis://redis:6379/0'
  fi
  printf '%s\n' \
    'RELAY_PUBLIC_DOMAIN=http://127.0.0.1' \
    "RELAY_PUBLIC_URL=$BASE_URL" \
    "RELAY_HTTP_PORT=$http_port" \
    "RELAY_HTTPS_PORT=$https_port" \
    'RELAY_CADDY_IMAGE=caddy:2.8-alpine' \
    'CADDY_HTTP_PORT=80' \
    'CADDY_HTTPS_PORT=443' \
    'RELAY_INTERNAL_PORT=8080' \
    'FRONT_INTERNAL_PORT=80' \
    "RELAY_STORAGE_MODE=$relay_storage_mode" \
    "RELAY_DATABASE_URL=$relay_database_url" \
    "RELAY_REDIS_URL=$relay_redis_url" \
    "RELAY_REDIS_PASSWORD=$redis_password" \
    'RELAY_INSTANCE_ID=client-backend-e2e' \
    'RELAY_PRESENCE_TTL=60s' \
    "RELAY_ENROLLMENT_TOKEN=$ENROLLMENT_TOKEN" \
    "RELAY_INTERNAL_TOKEN=$internal_token" \
    "RELAY_CREDENTIAL_KEY=$credential_key" \
    "RELAY_CREDENTIAL_TTL=$credential_ttl" \
    "ADMIN_INTERNAL_PORT=8081" \
    "ADMIN_USER=e2e-admin" \
    "ADMIN_PASSWORD=$ADMIN_PASSWORD" \
    "ADMIN_AUTH_KEY=$admin_auth_key" \
    "ADMIN_RELAY_INTERNAL_TOKEN=$internal_token" \
    "ADMIN_TRUSTED_PROXY_CIDRS=$caddy_ip/32" \
    'ADMIN_SESSION_TTL=24h' \
    'ADMIN_MAX_SESSIONS=32' \
    'ADMIN_LOGIN_MAX_ATTEMPTS=5' \
    'ADMIN_LOGIN_WINDOW=1m' \
    'ADMIN_LOGIN_BLOCK=5m' \
    'ADMIN_MAX_LOGIN_ENTRIES=4096' \
    'ADMIN_HTTP_READ_TIMEOUT=15s' \
    'ADMIN_HTTP_WRITE_TIMEOUT=15s' \
    'ADMIN_HTTP_IDLE_TIMEOUT=60s' \
    'ADMIN_HTTP_MAX_HEADER_BYTES=16384' \
    'RELAY_MAX_CONNECTIONS=2048' \
    'RELAY_MAX_ENROLLED_DEVICES=4096' \
    'RELAY_MAX_REVOKED_DEVICES=4096' \
    'RELAY_MAX_TRANSFER_SESSIONS=4096' \
    'RELAY_MAX_PENDING_FRAMES_PER_DEVICE=64' \
    'RELAY_MAX_PENDING_BYTES_PER_DEVICE=16777216' \
    'RELAY_MAX_FRAMES_PER_SECOND_PER_DEVICE=256' \
    'RELAY_MAX_BYTES_PER_SECOND_PER_DEVICE=67108864' \
    'RELAY_HTTP_READ_TIMEOUT=15s' \
    'RELAY_HTTP_WRITE_TIMEOUT=15s' \
    'RELAY_HTTP_IDLE_TIMEOUT=60s' \
    'RELAY_HTTP_MAX_HEADER_BYTES=16384' \
    "RELAY_TRUSTED_PROXY_CIDRS=$caddy_ip/32" \
    "RELAY_CADDY_IP=$caddy_ip" \
    "RELAY_NETWORK_SUBNET=$network_subnet" \
    "MYSQL_ROOT_PASSWORD=$mysql_root_password" \
    'MYSQL_DATABASE=relay' \
    "MYSQL_USER=$mysql_user" \
    "MYSQL_PASSWORD=$mysql_password" \
    "TELEMETRY_MYSQL_DSN=telemetry:${analytics_mysql_password}@tcp(analytics-mysql:3306)/telemetry?parseTime=true&loc=UTC" \
    "TELEMETRY_REDIS_URL=redis://:${analytics_redis_password}@analytics-redis:6379/0" \
    "TELEMETRY_AUTH_SECRET=$telemetry_auth_secret" \
    "ANALYTICS_MYSQL_PASSWORD=$analytics_mysql_password" \
    "ANALYTICS_MYSQL_ROOT_PASSWORD=$analytics_mysql_root_password" \
    "ANALYTICS_REDIS_PASSWORD=$analytics_redis_password" > "$ENV_FILE"

  COMPOSE_STARTED=1
  compose up -d --build
  export CLIENT_BACKEND_E2E_BASE_URL="$BASE_URL"
  export RELAY_ENROLLMENT_TOKEN="$ENROLLMENT_TOKEN"
  if [[ "$MODE" == strict ]]; then
    export CLIENT_BACKEND_E2E_STRICT=1
  fi
  wait_health
}

run_rust() {
  (cd "$ROOT_DIR/native/network_core" && \
    CLIENT_BACKEND_E2E_BASE_URL="$BASE_URL" \
    RELAY_ENROLLMENT_TOKEN="$ENROLLMENT_TOKEN" \
    cargo test -p network-relay --features test-support \
      --test client_backend_e2e --locked -- --ignored --test-threads=1)
}

build_rust_e2e() {
  (cd "$ROOT_DIR/native/network_core" && \
    cargo test -p network-relay --features test-support \
      --test client_backend_e2e --locked --no-run)
}

run_admin_revoke() {
  local cookie_file="$TMP_ROOT/admin-cookie"
  local login_body="$TMP_ROOT/admin-login.json"
  local status
  [[ -n "$ADMIN_USER" && -n "$ADMIN_PASSWORD" ]] || {
    echo "ENVIRONMENT GAP: strict active-revocation probe needs admin credentials" >&2
    return 2
  }
  # Keep credentials in a mode-600 temporary file and never in argv or logs.
  printf '{"username":"%s","password":"%s"}\n' \
    "$ADMIN_USER" "$ADMIN_PASSWORD" > "$login_body"
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --header 'Content-Type: application/json' \
    --cookie-jar "$cookie_file" --data-binary "@$login_body" \
    --output /dev/null --write-out '%{http_code}' \
    "$BASE_URL/api/admin/v1/auth/login" || true)"
  if [[ "$status" != 200 ]]; then
    echo "Strict admin login failed with HTTP $status" >&2
    return 1
  fi
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --cookie "$cookie_file" --request POST --output /dev/null \
    --write-out '%{http_code}' \
    "$BASE_URL/api/admin/v1/devices/e2e-rust-revoke-a/revoke" || true)"
  if [[ "$status" != 204 ]]; then
    echo "Strict admin revoke failed with HTTP $status" >&2
    return 1
  fi
}

assert_storage_after_restart() {
  local cookie_file="$TMP_ROOT/restart-admin-cookie"
  local login_body="$TMP_ROOT/restart-admin-login.json"
  local devices_body="$TMP_ROOT/devices-after-restart.json"
  local status
  [[ -n "$ADMIN_USER" && -n "$ADMIN_PASSWORD" ]] || return 0
  printf '{"username":"%s","password":"%s"}\n' \
    "$ADMIN_USER" "$ADMIN_PASSWORD" > "$login_body"
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --header 'Content-Type: application/json' \
    --cookie-jar "$cookie_file" --data-binary "@$login_body" \
    --output /dev/null --write-out '%{http_code}' \
    "$BASE_URL/api/admin/v1/auth/login" || true)"
  [[ "$status" == 200 ]] || {
    echo "Strict post-restart admin login failed with HTTP $status" >&2
    return 1
  }
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --cookie "$cookie_file" --output "$devices_body" \
    --write-out '%{http_code}' "$BASE_URL/api/admin/v1/devices" || true)"
  [[ "$status" == 200 ]] || {
    echo "Strict post-restart device snapshot failed with HTTP $status" >&2
    return 1
  }
  if [[ "$STORAGE_MODE" == mysql ]]; then
    grep -Fq 'e2e-rust-a' "$devices_body" || {
      echo "MySQL storage profile lost an enrolled device after Relay restart" >&2
      return 1
    }
    if grep -Fq 'e2e-rust-revoke-a' "$devices_body"; then
      echo "MySQL storage profile retained a revoked device after Relay restart" >&2
      return 1
    fi
  else
    if grep -Eq 'e2e-rust-(a|b)' "$devices_body"; then
      echo "Memory storage profile retained an enrollment after Relay restart" >&2
      return 1
    fi
  fi
}

run_rust_with_revocation() {
  local ready_file="$TMP_ROOT/revocation-ready"
  local done_file="$TMP_ROOT/revocation-done"
  local log_file="$TMP_ROOT/rust-revocation.log"
  local rust_pid attempt
  # Build before starting the marker handshake. GitHub runners may need more
  # than one minute to compile the Relay integration target on a cold cache.
  build_rust_e2e
  rm -f -- "$ready_file" "$done_file" "$log_file"
  (
    cd "$ROOT_DIR/native/network_core"
    CLIENT_BACKEND_E2E_BASE_URL="$BASE_URL" \
    RELAY_ENROLLMENT_TOKEN="$ENROLLMENT_TOKEN" \
    CLIENT_BACKEND_E2E_STRICT=1 \
    CLIENT_BACKEND_E2E_REVOCATION=1 \
    CLIENT_BACKEND_E2E_REVOCATION_READY_FILE="$ready_file" \
    CLIENT_BACKEND_E2E_REVOCATION_DONE_FILE="$done_file" \
    cargo test -p network-relay --features test-support \
      --test client_backend_e2e --locked -- --ignored --test-threads=1
  ) > "$log_file" 2>&1 &
  rust_pid=$!
  RUST_E2E_PID="$rust_pid"
  for attempt in $(seq 1 600); do
    if [[ -f "$ready_file" ]]; then
      break
    fi
    if ! kill -0 "$rust_pid" 2>/dev/null; then
      echo "Strict Rust revocation client exited before admin trigger" >&2
      RUST_E2E_PID=""
      return 1
    fi
    sleep 0.25
  done
  if [[ ! -f "$ready_file" ]]; then
    echo "Strict Rust revocation client did not publish its ready marker" >&2
    kill "$rust_pid" 2>/dev/null || true
    wait "$rust_pid" 2>/dev/null || true
    RUST_E2E_PID=""
    return 1
  fi
  if ! run_admin_revoke; then
    kill "$rust_pid" 2>/dev/null || true
    wait "$rust_pid" 2>/dev/null || true
    RUST_E2E_PID=""
    return 1
  fi
  : > "$done_file"
  if ! wait "$rust_pid"; then
    echo "Strict Rust revocation client failed" >&2
    RUST_E2E_PID=""
    return 1
  fi
  RUST_E2E_PID=""
}

run_dart() {
  (cd "$ROOT_DIR/apps/ssh_mobile_full" && \
    CLIENT_BACKEND_E2E_BASE_URL="$BASE_URL" \
    RELAY_ENROLLMENT_TOKEN="$ENROLLMENT_TOKEN" \
    HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= ALL_PROXY= all_proxy= \
    NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 \
    flutter test --no-pub test/integration/client_backend/relay_bootstrap_e2e_test.dart)
}

run_strict_lifecycle_probes() {
  # The live client test covers credential refresh/reconnect when the caller
  # selects a short TTL.  These process-level probes verify that restarting
  # either proxy or Relay leaves the new route healthy and still rejects an
  # unauthenticated request.  `CLIENT_BACKEND_E2E_STORAGE=mysql` additionally
  # starts the Compose storage profile; the active admin-revoke probe runs for
  # the isolated Compose deployment or when external admin credentials are set.
  if ((COMPOSE_STARTED)); then
    compose restart caddy >/dev/null
    wait_health
    assert_relay_routes

    # Deployment regression probe: verify public /healthz reflects Relay health
    # and that front SPA does NOT mask Relay failure.
    compose stop relay >/dev/null
    local down_status
    down_status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 3 \
      --output /dev/null --write-out '%{http_code}' "$BASE_URL/healthz" || true)"
    if [[ "$down_status" == 204 ]]; then
      echo "Deployment regression: public /healthz returned 204 while Relay was stopped" >&2
      return 1
    fi
    compose start relay >/dev/null
    wait_health
    assert_relay_routes

    compose restart relay >/dev/null
    wait_health
    assert_relay_routes
    assert_storage_after_restart
  fi
}

if [[ -n "$BASE_URL" || -n "$ENROLLMENT_TOKEN" ]]; then
  if [[ -z "$BASE_URL" || -z "$ENROLLMENT_TOKEN" ]]; then
    echo "CLIENT_BACKEND_E2E_BASE_URL and RELAY_ENROLLMENT_TOKEN must be provided together" >&2
    exit 64
  fi
  need_command curl
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/client-backend-e2e.XXXXXX")"
  chmod 700 "$TMP_ROOT"
else
  start_compose
fi

if [[ "$MODE" == strict ]]; then
  export CLIENT_BACKEND_E2E_STRICT=1
fi

assert_relay_routes
telemetry_ingestion_probe
run_dart
if [[ "$MODE" == strict && -n "$ADMIN_USER" && -n "$ADMIN_PASSWORD" ]]; then
  run_rust_with_revocation
elif [[ "$MODE" == strict ]]; then
  run_rust
  echo "Strict active-revocation probe skipped: admin credentials were not supplied" >&2
else
  run_rust
fi
if [[ "$MODE" == strict ]]; then
  run_strict_lifecycle_probes
  printf 'CLIENT_BACKEND_STRICT_PASS\n'
else
  printf 'CLIENT_BACKEND_SMOKE_PASS\n'
fi
