#!/usr/bin/env bash

# Collect Go Relay coverage independently from the daily full test gate.
# Generated protobuf and telemetry catalog code plus the process-only
# cmd/{relay,admin}/main.go bootstraps are excluded from the metric. Every hand-written
# Relay service, including telemetry, remains in scope and must reach the
# configured thresholds.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
RELAY_DIR="$ROOT_DIR/relay"
MINIMUM="${BACKEND_COVERAGE_MINIMUM:-90}"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssh-mobile-backend-coverage.XXXXXX")"
RAW_PROFILE="$RUN_DIR/relay.raw.out"
FILTERED_PROFILE="$RUN_DIR/relay.filtered.out"
SUMMARY_FILE="$RUN_DIR/relay.summary.txt"
TELEMETRY_PROFILE="$RUN_DIR/telemetry.filtered.out"
TELEMETRY_SUMMARY_FILE="$RUN_DIR/telemetry.summary.txt"

MYSQL_CONTAINER="ssh-mobile-backend-coverage-mysql-$$"
REDIS_CONTAINER="ssh-mobile-backend-coverage-redis-$$"
ANALYTICS_MYSQL_CONTAINER="ssh-mobile-backend-coverage-analytics-mysql-$$"
ANALYTICS_REDIS_CONTAINER="ssh-mobile-backend-coverage-analytics-redis-$$"

cleanup() {
  docker rm -f "$MYSQL_CONTAINER" "$REDIS_CONTAINER" \
    "$ANALYTICS_MYSQL_CONTAINER" "$ANALYTICS_REDIS_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! [[ "$MINIMUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "BACKEND_COVERAGE_MINIMUM must be numeric: $MINIMUM" >&2
  exit 64
fi
TELEMETRY_MINIMUM="${BACKEND_TELEMETRY_COVERAGE_MINIMUM:-$MINIMUM}"
if ! [[ "$TELEMETRY_MINIMUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "BACKEND_TELEMETRY_COVERAGE_MINIMUM must be numeric: $TELEMETRY_MINIMUM" >&2
  exit 64
fi
if ! command -v go >/dev/null 2>&1; then
  echo 'Go is required for backend coverage.' >&2
  exit 69
fi

MYSQL_DSN="${RELAY_TEST_MYSQL_DSN:-}"
REDIS_URL="${RELAY_TEST_REDIS_URL:-}"
TELEMETRY_MYSQL_DSN="${TELEMETRY_TEST_MYSQL_DSN:-${TELEMETRY_MYSQL_DSN:-}}"
TELEMETRY_REDIS_URL="${TELEMETRY_TEST_REDIS_URL:-${TELEMETRY_REDIS_URL:-}}"
if [[ -z "$MYSQL_DSN" || -z "$REDIS_URL" || -z "$TELEMETRY_MYSQL_DSN" || -z "$TELEMETRY_REDIS_URL" ]]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo 'Docker daemon is required unless Relay and telemetry test endpoints are provided.' >&2
    exit 69
  fi

  if [[ -z "$MYSQL_DSN" ]]; then
    docker run -d --rm --name "$MYSQL_CONTAINER" \
      -p 127.0.0.1::3306 \
      -e MYSQL_ROOT_PASSWORD=root \
      -e MYSQL_DATABASE=relay \
      -e MYSQL_USER=relay \
      -e MYSQL_PASSWORD=relay \
      mysql:8.4@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb >/dev/null || exit 69
    MYSQL_PORT="$(docker port "$MYSQL_CONTAINER" 3306/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
    if [[ ! "$MYSQL_PORT" =~ ^[0-9]+$ ]]; then
      echo 'Docker did not publish the temporary Relay MySQL port.' >&2
      exit 69
    fi
    mysql_ready=0
    for attempt in $(seq 1 60); do
      if docker exec "$MYSQL_CONTAINER" mysqladmin ping -h 127.0.0.1 -urelay -prelay >/dev/null 2>&1; then
        mysql_ready=1
        break
      fi
      sleep 2
    done
    ((mysql_ready)) || { echo 'Temporary Relay MySQL did not become ready.' >&2; exit 69; }
    MYSQL_DSN="relay:relay@tcp(127.0.0.1:${MYSQL_PORT})/relay?parseTime=true&loc=UTC"
  fi
  if [[ -z "$REDIS_URL" ]]; then
    docker run -d --rm --name "$REDIS_CONTAINER" \
      -p 127.0.0.1::6379 \
      redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf >/dev/null || exit 69
    REDIS_PORT="$(docker port "$REDIS_CONTAINER" 6379/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
    if [[ ! "$REDIS_PORT" =~ ^[0-9]+$ ]]; then
      echo 'Docker did not publish the temporary Relay Redis port.' >&2
      exit 69
    fi
    redis_ready=0
    for attempt in $(seq 1 30); do
      if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | rg -q '^PONG$'; then
        redis_ready=1
        break
      fi
      sleep 2
    done
    ((redis_ready)) || { echo 'Temporary Relay Redis did not become ready.' >&2; exit 69; }
    REDIS_URL="redis://127.0.0.1:${REDIS_PORT}/0"
  fi
  analytics_mysql_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  analytics_mysql_root_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  analytics_redis_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  if [[ -z "$TELEMETRY_MYSQL_DSN" ]]; then
    docker run -d --rm --name "$ANALYTICS_MYSQL_CONTAINER" \
      -p 127.0.0.1::3306 \
      -e MYSQL_ROOT_PASSWORD="$analytics_mysql_root_password" \
      -e MYSQL_DATABASE=telemetry \
      -e MYSQL_USER=telemetry \
      -e MYSQL_PASSWORD="$analytics_mysql_password" \
      mysql:8.4@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb >/dev/null || exit 69
    ANALYTICS_MYSQL_PORT="$(docker port "$ANALYTICS_MYSQL_CONTAINER" 3306/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
    if [[ ! "$ANALYTICS_MYSQL_PORT" =~ ^[0-9]+$ ]]; then
      echo 'Docker did not publish the temporary Analytics MySQL port.' >&2
      exit 69
    fi
    analytics_mysql_ready=0
    for attempt in $(seq 1 60); do
      if docker exec "$ANALYTICS_MYSQL_CONTAINER" mysqladmin ping -h 127.0.0.1 -utelemetry -p"$analytics_mysql_password" >/dev/null 2>&1; then
        analytics_mysql_ready=1
        break
      fi
      sleep 2
    done
    ((analytics_mysql_ready)) || { echo 'Temporary Analytics MySQL did not become ready.' >&2; exit 69; }
    TELEMETRY_MYSQL_DSN="telemetry:${analytics_mysql_password}@tcp(127.0.0.1:${ANALYTICS_MYSQL_PORT})/telemetry?parseTime=true&loc=UTC"
  fi
  if [[ -z "$TELEMETRY_REDIS_URL" ]]; then
    docker run -d --rm --name "$ANALYTICS_REDIS_CONTAINER" \
      -p 127.0.0.1::6379 \
      -e ANALYTICS_REDIS_PASSWORD="$analytics_redis_password" \
      redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf sh -ec 'exec redis-server --maxmemory 64mb --maxmemory-policy noeviction --requirepass "$ANALYTICS_REDIS_PASSWORD"' >/dev/null || exit 69
    ANALYTICS_REDIS_PORT="$(docker port "$ANALYTICS_REDIS_CONTAINER" 6379/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
    if [[ ! "$ANALYTICS_REDIS_PORT" =~ ^[0-9]+$ ]]; then
      echo 'Docker did not publish the temporary Analytics Redis port.' >&2
      exit 69
    fi
    analytics_redis_ready=0
    for attempt in $(seq 1 30); do
      if docker exec "$ANALYTICS_REDIS_CONTAINER" redis-cli -a "$analytics_redis_password" --no-auth-warning ping 2>/dev/null | rg -q '^PONG$'; then
        analytics_redis_ready=1
        break
      fi
      sleep 2
    done
    ((analytics_redis_ready)) || { echo 'Temporary Analytics Redis did not become ready.' >&2; exit 69; }
    TELEMETRY_REDIS_URL="redis://:${analytics_redis_password}@127.0.0.1:${ANALYTICS_REDIS_PORT}/0"
  fi
fi

printf 'Backend coverage threshold: %s%%\n' "$MINIMUM"
printf 'Coverage artifacts: %s\n' "$RUN_DIR"
printf 'Scope excludes generated protobuf/catalog code and process bootstrap cmd/{relay,admin}/main.go.\n'

if ! COVERPKG="$(cd "$RELAY_DIR" && go list ./internal/... ./cmd/... | paste -sd, -)"; then
  echo 'Unable to enumerate Relay production packages for coverage.' >&2
  exit 69
fi
if [[ -z "$COVERPKG" ]]; then
  echo 'Unable to enumerate hand-written Relay production packages for coverage.' >&2
  exit 69
fi
printf 'Instrumented production packages: %s\n' "$COVERPKG"

if ! (cd "$RELAY_DIR" && \
  RELAY_TEST_MYSQL_DSN="$MYSQL_DSN" \
  RELAY_TEST_REDIS_URL="$REDIS_URL" \
  TELEMETRY_TEST_MYSQL_DSN="$TELEMETRY_MYSQL_DSN" \
  TELEMETRY_MYSQL_DSN="$TELEMETRY_MYSQL_DSN" \
  TELEMETRY_TEST_REDIS_URL="$TELEMETRY_REDIS_URL" \
  TELEMETRY_REDIS_URL="$TELEMETRY_REDIS_URL" \
  go test ./... -count=1 -covermode=atomic -coverpkg="$COVERPKG" -coverprofile="$RAW_PROFILE"); then
  echo 'Backend tests failed; coverage was not accepted.' >&2
  exit 1
fi

{
  sed -n '1p' "$RAW_PROFILE"
  sed -n '2,$p' "$RAW_PROFILE" | rg -v '/relay_v2\.pb\.go:|/cmd/(relay|admin)/main\.go:|/internal/telemetry/generated/'
} > "$FILTERED_PROFILE"

{
  sed -n '1p' "$RAW_PROFILE"
  sed -n '2,$p' "$RAW_PROFILE" | rg '/internal/telemetry/' | rg -v '/internal/telemetry/generated/'
} > "$TELEMETRY_PROFILE"
if ! rg -q '/internal/telemetry/[^/]+\.go:' "$TELEMETRY_PROFILE"; then
  echo 'Telemetry coverage profile is empty; integration tests did not instrument telemetry production code.' >&2
  exit 65
fi

(cd "$RELAY_DIR" && go tool cover -func="$FILTERED_PROFILE") | tee "$SUMMARY_FILE"
total="$(awk '$1 == "total:" {gsub(/%/, "", $NF); print $NF}' "$SUMMARY_FILE")"
if [[ -z "$total" ]]; then
  echo 'Unable to read the filtered Go coverage total.' >&2
  exit 65
fi
printf 'Filtered backend line coverage: %s%%\n' "$total"
if ! awk -v value="$total" -v minimum="$MINIMUM" 'BEGIN { exit !(value + 0 >= minimum + 0) }'; then
  echo "Backend coverage is below the required ${MINIMUM}%. Add meaningful boundary, failure, and state-transition tests." >&2
  exit 1
fi
printf 'Backend coverage gate passed at %s%%.\n' "$total"

(cd "$RELAY_DIR" && go tool cover -func="$TELEMETRY_PROFILE") | tee "$TELEMETRY_SUMMARY_FILE"
telemetry_total="$(awk '$1 == "total:" {gsub(/%/, "", $NF); print $NF}' "$TELEMETRY_SUMMARY_FILE")"
if [[ -z "$telemetry_total" ]]; then
  echo 'Unable to read the telemetry coverage total.' >&2
  exit 65
fi
printf 'Filtered telemetry line coverage: %s%%\n' "$telemetry_total"
if ! awk -v value="$telemetry_total" -v minimum="$TELEMETRY_MINIMUM" 'BEGIN { exit !(value + 0 >= minimum + 0) }'; then
  echo "Telemetry coverage is below the required ${TELEMETRY_MINIMUM}%. Add meaningful telemetry integration and state-transition tests." >&2
  exit 1
fi
printf 'Telemetry coverage gate passed at %s%%.\n' "$telemetry_total"
