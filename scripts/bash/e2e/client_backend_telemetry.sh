#!/usr/bin/env bash

# Live Analytics readiness and ingestion probe sourced by client_backend_e2e.sh.

telemetry_proof() {
  local device_id="$1" secret="$2" exp_epoch="$3"
  TELEMETRY_DEVICE_ID="$device_id" TELEMETRY_DEVICE_SECRET="$secret" TELEMETRY_EXP_EPOCH="$exp_epoch" python3 - <<'PY'
import hashlib
import hmac
import os

device_id = os.environ['TELEMETRY_DEVICE_ID']
stored_hash = hashlib.sha256(os.environ['TELEMETRY_DEVICE_SECRET'].encode()).hexdigest()
message = f"telemetry:auth:{device_id}:{os.environ['TELEMETRY_EXP_EPOCH']}"
print(hmac.new(stored_hash.encode(), message.encode(), hashlib.sha256).hexdigest())
PY
}

telemetry_ingestion_probe() {
  local cookie_file="$TMP_ROOT/telemetry-admin-cookie"
  local login_body="$TMP_ROOT/telemetry-admin-login.json"
  local register_body="$TMP_ROOT/telemetry-register.json"
  local register_response="$TMP_ROOT/telemetry-register-response.json"
  local auth_body="$TMP_ROOT/telemetry-auth.json"
  local auth_response="$TMP_ROOT/telemetry-auth-response.json"
  local ingest_body="$TMP_ROOT/telemetry-ingest.json"
  local ingest_response="$TMP_ROOT/telemetry-ingest-response.json"
  local events_response="$TMP_ROOT/telemetry-events-response.json"
  local overview_response="$TMP_ROOT/telemetry-overview-response.json"
  local device_id='e2e-telemetry'
  local event_id="e2e-telemetry-$(random_hex 12)"
  local status secret exp_epoch proof token occurred_at

  [[ -n "$ADMIN_USER" && -n "$ADMIN_PASSWORD" ]] || {
    echo 'Telemetry E2E requires CLIENT_BACKEND_E2E_ADMIN_USER and CLIENT_BACKEND_E2E_ADMIN_PASSWORD.' >&2
    return 125
  }
  for attempt in $(seq 1 90); do
    status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 5 \
      --output /dev/null --write-out '%{http_code}' "$BASE_URL/api/v1/telemetry/policy" || true)"
    [[ "$status" == 200 ]] && break
    if [[ "$attempt" == 90 ]]; then
      echo "Telemetry policy readiness probe did not become ready: HTTP $status" >&2
      return 1
    fi
    sleep 1
  done

  printf '{"username":"%s","password":"%s"}\n' "$ADMIN_USER" "$ADMIN_PASSWORD" > "$login_body"
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --header 'Content-Type: application/json' --cookie-jar "$cookie_file" \
    --data-binary "@$login_body" --output /dev/null --write-out '%{http_code}' \
    "$BASE_URL/api/admin/v1/auth/login" || true)"
  [[ "$status" == 200 ]] || { echo "Telemetry admin login failed with HTTP $status" >&2; return 1; }

  printf '{"deviceId":"%s"}\n' "$device_id" > "$register_body"
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --header 'Content-Type: application/json' --cookie "$cookie_file" \
    --data-binary "@$register_body" --output "$register_response" \
    --write-out '%{http_code}' "$BASE_URL/api/admin/v1/telemetry/devices" || true)"
  [[ "$status" == 201 ]] || { echo "Telemetry device registration failed with HTTP $status" >&2; return 1; }
  secret="$(python3 - "$register_response" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    print(json.load(handle)['secret'])
PY
)"
  [[ -n "$secret" ]] || { echo 'Telemetry registration response did not contain a secret.' >&2; return 1; }

  exp_epoch=$(( $(date +%s) + 60 ))
  proof="$(telemetry_proof "$device_id" "$secret" "$exp_epoch")"
  printf '{"deviceId":"%s","proof":"%s","expEpoch":%s}\n' \
    "$device_id" "$proof" "$exp_epoch" > "$auth_body"
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --header 'Content-Type: application/json' --data-binary "@$auth_body" \
    --output "$auth_response" --write-out '%{http_code}' \
    "$BASE_URL/api/v1/telemetry/auth" || true)"
  [[ "$status" == 200 ]] || { echo "Telemetry device authentication failed with HTTP $status" >&2; return 1; }
  token="$(python3 - "$auth_response" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    print(json.load(handle)['token'])
PY
)"
  [[ -n "$token" ]] || { echo 'Telemetry authentication response did not contain a token.' >&2; return 1; }

  occurred_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"records":[{"eventId":"%s","recordType":"analytics","eventName":"ssh.session.started","eventVersion":1,"deviceId":"%s","sessionId":"e2e-telemetry-session","traceId":"e2e-telemetry-trace","occurredAt":"%s","feature":"ssh","severity":"info","appVersion":"ci","buildNumber":"ci","platform":"linux","properties":{"session_type":"interactive","auth_method":"key"}}]}\n' \
    "$event_id" "$device_id" "$occurred_at" > "$ingest_body"
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --header 'Content-Type: application/json' --header "X-Device-Id: $device_id" \
    --header "Authorization: Bearer $token" --data-binary "@$ingest_body" \
    --output "$ingest_response" --write-out '%{http_code}' \
    "$BASE_URL/api/v1/telemetry/ingest" || true)"
  [[ "$status" == 200 ]] || { echo "Telemetry ingestion failed with HTTP $status" >&2; return 1; }
  grep -Fq 'accepted' "$ingest_response" || { echo 'Telemetry ingestion did not accept the event.' >&2; return 1; }

  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --cookie "$cookie_file" --output "$events_response" --write-out '%{http_code}' \
    "$BASE_URL/api/admin/v1/telemetry/events?eventName=ssh.session.started&deviceId=$device_id" || true)"
  [[ "$status" == 200 ]] || { echo "Telemetry event query failed with HTTP $status" >&2; return 1; }
  grep -Fq "$event_id" "$events_response" || { echo 'Telemetry event was not readable after ingestion.' >&2; return 1; }
  status="$(curl "${CURL_TLS_ARGS[@]}" --silent --show-error --max-time 10 \
    --cookie "$cookie_file" --output "$overview_response" --write-out '%{http_code}' \
    "$BASE_URL/api/admin/v1/telemetry/overview?timeRange=24h" || true)"
  [[ "$status" == 200 ]] || { echo "Telemetry overview readiness query failed with HTTP $status" >&2; return 1; }
  printf 'TELEMETRY_INGESTION_PASS event=%s\n' "$event_id"
}
