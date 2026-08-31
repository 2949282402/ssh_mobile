#!/usr/bin/env bash

# External-deployment online E2E.
#
# Unlike client_backend_e2e.sh this entry point never starts Compose. It
# requires an explicit target, enrollment token, administrator credentials, and
# a confirmation marker. The Go suite covers the HTTP/Admin/Telemetry branches;
# the existing Rust/Dart live clients cover control, reservation data, and App
# bootstrap. Every created device is prefixed with a unique run id and revoked
# during cleanup. Telemetry rows remain as auditable test evidence because the
# production API intentionally has no destructive event-delete endpoint.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
MODE="${1:-full}"
if [[ "$MODE" != full ]]; then
  echo "Usage: ONLINE_E2E_CONFIRM=RUN bash scripts/bash/e2e/online_e2e.sh [full]" >&2
  exit 64
fi

BASE_URL="${ONLINE_E2E_BASE_URL:-${CLIENT_BACKEND_E2E_BASE_URL:-}}"
ENROLLMENT_TOKEN="${RELAY_ENROLLMENT_TOKEN:-}"
ADMIN_USER="${ONLINE_E2E_ADMIN_USER:-${CLIENT_BACKEND_E2E_ADMIN_USER:-}}"
ADMIN_PASSWORD="${ONLINE_E2E_ADMIN_PASSWORD:-${CLIENT_BACKEND_E2E_ADMIN_PASSWORD:-}}"
CA_FILE="${ONLINE_E2E_CA_FILE:-${CLIENT_BACKEND_E2E_CA_FILE:-}}"
RUN_ID="${ONLINE_E2E_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-${BASHPID}}"
TMP_ROOT=""
CURL_TLS_ARGS=()

if [[ "${ONLINE_E2E_CONFIRM:-}" != RUN ]]; then
  echo "Refusing online-e2e: set ONLINE_E2E_CONFIRM=RUN to authorize test data writes." >&2
  exit 64
fi
if [[ -z "$BASE_URL" || -z "$ENROLLMENT_TOKEN" || -z "$ADMIN_USER" || -z "$ADMIN_PASSWORD" ]]; then
  echo "ONLINE_E2E_BASE_URL, RELAY_ENROLLMENT_TOKEN, ONLINE_E2E_ADMIN_USER, and ONLINE_E2E_ADMIN_PASSWORD are required." >&2
  exit 64
fi
if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9_-]{1,24}$ ]]; then
  echo "ONLINE_E2E_RUN_ID must contain only ASCII letters, digits, '_' or '-' and be at most 24 characters." >&2
  exit 64
fi
DEVICE_PREFIX="online-e2e-${RUN_ID}-"
case "$BASE_URL" in
  http://*|https://*) ;;
  *)
    echo "ONLINE_E2E_BASE_URL must be an absolute http(s) URL." >&2
    exit 64
    ;;
esac
if [[ "$BASE_URL" == http://127.0.0.1* || "$BASE_URL" == https://127.0.0.1* ||
  "$BASE_URL" == http://localhost* || "$BASE_URL" == https://localhost* ||
  "$BASE_URL" == http://\[::1\]* || "$BASE_URL" == https://\[::1\]* ]]; then
  if [[ "${ONLINE_E2E_ALLOW_LOCAL:-}" != 1 ]]; then
    echo "Refusing loopback target; set ONLINE_E2E_ALLOW_LOCAL=1 only for an explicitly isolated deployment." >&2
    exit 64
  fi
fi
need_command() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "ENVIRONMENT GAP: required command is unavailable: $command_name" >&2
      exit 125
    }
  done
}

need_command bash cargo curl flutter go python3

if [[ -n "$CA_FILE" ]]; then
  [[ -r "$CA_FILE" ]] || {
    echo "ONLINE_E2E_CA_FILE is not readable." >&2
    exit 64
  }
  CA_FILE="$(python3 - "$CA_FILE" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]))
PY
)"
  CURL_TLS_ARGS=(--cacert "$CA_FILE")
  export CLIENT_BACKEND_E2E_CA_FILE="$CA_FILE"
fi

if ! python3 - "$BASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit

parsed = urlsplit(sys.argv[1])
if (
    parsed.scheme not in {"http", "https"}
    or not parsed.netloc
    or parsed.path not in {"", "/"}
    or parsed.query
    or parsed.fragment
    or parsed.username
    or parsed.password
):
    raise SystemExit(1)
PY
then
  echo "ONLINE_E2E_BASE_URL must be an origin URL without a path, query, fragment, or credentials." >&2
  exit 64
fi

# Keep all paired launchers on one canonical origin so their path joins do not
# accidentally produce `//healthz` when the caller supplied one trailing slash.
BASE_URL="${BASE_URL%/}"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ssh-mobile-online-e2e.XXXXXX")"
chmod 700 "$TMP_ROOT"
COOKIE_FILE="$TMP_ROOT/admin-cookie"
LOGIN_BODY="$TMP_ROOT/admin-login.json"
DEVICES_BODY="$TMP_ROOT/devices.json"
DEVICE_IDS="$TMP_ROOT/device-ids"

cleanup_devices() {
  local status=0 device_id revoke_status
  umask 077
  ONLINE_E2E_ADMIN_USER="$ADMIN_USER" ONLINE_E2E_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    python3 - "$LOGIN_BODY" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(
        {
            "username": os.environ["ONLINE_E2E_ADMIN_USER"],
            "password": os.environ["ONLINE_E2E_ADMIN_PASSWORD"],
        },
        target,
    )
    target.write("\n")
PY
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --header 'Content-Type: application/json' --cookie-jar "$COOKIE_FILE" \
    --data-binary "@$LOGIN_BODY" --output /dev/null --write-out '%{http_code}' \
    "$BASE_URL/api/admin/v1/auth/login" || true)"
  if [[ "$status" != 200 ]]; then
    echo "CLEANUP GAP: administrator login returned HTTP $status; test devices may remain enrolled." >&2
    return 1
  fi
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --cookie "$COOKIE_FILE" --output "$DEVICES_BODY" --write-out '%{http_code}' \
    "$BASE_URL/api/admin/v1/devices" || true)"
  if [[ "$status" != 200 ]]; then
    echo "CLEANUP GAP: device listing returned HTTP $status; test devices may remain enrolled." >&2
    return 1
  fi
  status=0
  if ! python3 - "$DEVICES_BODY" "$DEVICE_PREFIX" > "$DEVICE_IDS" <<'PY'
import json
import sys

path, prefix = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    payload = json.load(source)
items = payload.get("items", [])
if not isinstance(items, list):
    raise SystemExit("device listing items must be an array")
for item in items:
    device_id = item.get("device_id")
    if isinstance(device_id, str) and device_id.startswith(prefix):
        print(device_id)
PY
  then
    echo "CLEANUP GAP: device listing was not valid JSON; test devices may remain enrolled." >&2
    return 1
  fi
  while IFS= read -r device_id; do
    [[ -n "$device_id" ]] || continue
    revoke_status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
      --cookie "$COOKIE_FILE" --request POST --output /dev/null \
      --write-out '%{http_code}' "$BASE_URL/api/admin/v1/devices/$device_id/revoke" || true)"
    case "$revoke_status" in
      204|404) ;;
      *)
        echo "CLEANUP GAP: revoking a test device returned HTTP $revoke_status." >&2
        status=1
        ;;
    esac
  done < "$DEVICE_IDS"
  revoke_status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --cookie "$COOKIE_FILE" --request POST --output /dev/null \
    --write-out '%{http_code}' "$BASE_URL/api/admin/v1/auth/logout" || true)"
  if [[ "$revoke_status" != 204 ]]; then
    echo "CLEANUP GAP: administrator logout returned HTTP $revoke_status." >&2
    status=1
  fi
  return "${status:-0}"
}

cleanup() {
  local exit_status=$?
  local cleanup_status=0
  set +e
  if [[ -z "$TMP_ROOT" ]]; then
    exit "$exit_status"
  fi
  cleanup_devices || cleanup_status=$?
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf -- "$TMP_ROOT"
  fi
  if (( exit_status == 0 && cleanup_status != 0 )); then
    exit_status=$cleanup_status
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

export CLIENT_BACKEND_E2E_BASE_URL="$BASE_URL"
export RELAY_ENROLLMENT_TOKEN="$ENROLLMENT_TOKEN"
export CLIENT_BACKEND_E2E_ADMIN_USER="$ADMIN_USER"
export CLIENT_BACKEND_E2E_ADMIN_PASSWORD="$ADMIN_PASSWORD"
export CLIENT_BACKEND_E2E_DEVICE_PREFIX="$DEVICE_PREFIX"
export CLIENT_BACKEND_E2E_REVOCATION_DEVICE_ID="${DEVICE_PREFIX}e2e-rust-revoke-a"
export CLIENT_BACKEND_E2E_ONLINE=1
export ONLINE_E2E_BASE_URL="$BASE_URL"
export ONLINE_E2E_ADMIN_USER="$ADMIN_USER"
export ONLINE_E2E_ADMIN_PASSWORD="$ADMIN_PASSWORD"
export ONLINE_E2E_RUN_ID="$RUN_ID"

echo "Online E2E target: $BASE_URL"
echo "Online E2E run id: $RUN_ID"

# Go owns HTTP/Admin/Telemetry branch coverage. Use a temporary build cache so
# a locked-down workstation does not require write access to its global cache.
(
  cd "$ROOT_DIR/relay"
  GOCACHE="$TMP_ROOT/go-cache" \
    go test -tags online_e2e ./tests/online_e2e -count=1 -timeout "${ONLINE_E2E_GO_TIMEOUT:-10m}"
)

# Real Rust control/reservation data and Full-App bootstrap use the existing
# cross-process launcher in external mode. ONLINE=1 keeps strict revocation
# coverage while avoiding the 46-second short-TTL assertion, which is not valid
# against a production 24h credential TTL.
bash "$ROOT_DIR/scripts/bash/e2e/client_backend_e2e.sh" strict

printf 'ONLINE_E2E_PASS run_id=%s\n' "$RUN_ID"
