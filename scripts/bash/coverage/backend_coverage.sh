#!/usr/bin/env bash

# Collect Go Relay coverage independently from the daily full test gate.
# Generated protobuf code and the process-only cmd/relay/main.go bootstrap are
# excluded from the metric; hand-written Relay services and the v2 wire codec
# remain in scope and must reach the configured threshold.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
RELAY_DIR="$ROOT_DIR/relay"
MINIMUM="${BACKEND_COVERAGE_MINIMUM:-80}"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssh-mobile-backend-coverage.XXXXXX")"
RAW_PROFILE="$RUN_DIR/relay.raw.out"
FILTERED_PROFILE="$RUN_DIR/relay.filtered.out"
SUMMARY_FILE="$RUN_DIR/relay.summary.txt"

MYSQL_CONTAINER="ssh-mobile-backend-coverage-mysql-$$"
REDIS_CONTAINER="ssh-mobile-backend-coverage-redis-$$"

cleanup() {
  docker rm -f "$MYSQL_CONTAINER" "$REDIS_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! [[ "$MINIMUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "BACKEND_COVERAGE_MINIMUM must be numeric: $MINIMUM" >&2
  exit 64
fi
if ! command -v go >/dev/null 2>&1; then
  echo 'Go is required for backend coverage.' >&2
  exit 69
fi

MYSQL_DSN="${RELAY_TEST_MYSQL_DSN:-}"
REDIS_URL="${RELAY_TEST_REDIS_URL:-}"
if [[ -z "$MYSQL_DSN" || -z "$REDIS_URL" ]]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo 'Docker daemon is required unless RELAY_TEST_MYSQL_DSN and RELAY_TEST_REDIS_URL are provided.' >&2
    exit 69
  fi

  docker run -d --rm --name "$MYSQL_CONTAINER" \
    -p 127.0.0.1::3306 \
    -e MYSQL_ROOT_PASSWORD=root \
    -e MYSQL_DATABASE=relay \
    -e MYSQL_USER=relay \
    -e MYSQL_PASSWORD=relay \
    mysql:8.4 >/dev/null || exit 69
  docker run -d --rm --name "$REDIS_CONTAINER" \
    -p 127.0.0.1::6379 \
    redis:7-alpine >/dev/null || exit 69

  MYSQL_PORT="$(docker port "$MYSQL_CONTAINER" 3306/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  REDIS_PORT="$(docker port "$REDIS_CONTAINER" 6379/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  if [[ ! "$MYSQL_PORT" =~ ^[0-9]+$ || ! "$REDIS_PORT" =~ ^[0-9]+$ ]]; then
    echo 'Docker did not publish the temporary Relay storage ports.' >&2
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
  redis_ready=0
  for attempt in $(seq 1 30); do
    if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | rg -q '^PONG$'; then
      redis_ready=1
      break
    fi
    sleep 2
  done
  if ((mysql_ready == 0 || redis_ready == 0)); then
    echo 'Temporary MySQL/Redis services did not become ready.' >&2
    exit 69
  fi

  MYSQL_DSN="relay:relay@tcp(127.0.0.1:${MYSQL_PORT})/relay?parseTime=true&loc=UTC"
  REDIS_URL="redis://127.0.0.1:${REDIS_PORT}/0"
fi

printf 'Backend coverage threshold: %s%%\n' "$MINIMUM"
printf 'Coverage artifacts: %s\n' "$RUN_DIR"
printf 'Scope excludes generated relay_v2.pb.go and process bootstrap cmd/relay/main.go.\n'

if ! (cd "$RELAY_DIR" && \
  RELAY_TEST_MYSQL_DSN="$MYSQL_DSN" \
  RELAY_TEST_REDIS_URL="$REDIS_URL" \
  go test ./... -count=1 -covermode=atomic -coverprofile="$RAW_PROFILE"); then
  echo 'Backend tests failed; coverage was not accepted.' >&2
  exit 1
fi

{
  sed -n '1p' "$RAW_PROFILE"
  sed -n '2,$p' "$RAW_PROFILE" | rg -v '/relay_v2\.pb\.go:|/cmd/relay/main\.go:'
} > "$FILTERED_PROFILE"

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
