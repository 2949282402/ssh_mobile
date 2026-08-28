#!/usr/bin/env bash

# Collect the client-side Network Protocol V2 coverage independently from the
# daily Full App regression gate. The scope is the App-owned Network V2
# service boundary touched by this plan; it is deliberately not presented as
# coverage for every unrelated UI feature in the Full App.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
APP_DIR="$ROOT_DIR/apps/ssh_mobile_full"
MINIMUM="${CLIENT_COVERAGE_MINIMUM:-90}"
FLUTTER_TIMEOUT="${CLIENT_FLUTTER_COVERAGE_TIMEOUT:-30m}"
FLUTTER_BIN="${CLIENT_FLUTTER_BIN:-flutter}"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssh-mobile-client-coverage.XXXXXX")"
FLUTTER_CONFIG_ROOT="$RUN_DIR/flutter-config"

cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

for argument in "$@"; do
  case "$argument" in
    --no-bootstrap)
      # Dependencies are intentionally not bootstrapped by this focused gate.
      ;;
    *)
      echo "Unknown client coverage option: $argument" >&2
      exit 64
      ;;
  esac
done

if ! [[ "$MINIMUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "CLIENT_COVERAGE_MINIMUM must be numeric: $MINIMUM" >&2
  exit 64
fi
if [[ "$FLUTTER_BIN" == */* ]]; then
  if [[ ! -x "$FLUTTER_BIN" ]]; then
    echo "Flutter runner is not executable: $FLUTTER_BIN" >&2
    exit 69
  fi
elif ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  echo "Flutter runner is required for client coverage: $FLUTTER_BIN" >&2
  exit 69
fi
if ! command -v dart >/dev/null 2>&1; then
  echo 'dart is required for client coverage.' >&2
  exit 69
fi

mkdir -p "$FLUTTER_CONFIG_ROOT"
cd "$APP_DIR"

test_files=(
  test/services/network/network_protocol_v2_codec_test.dart
  test/services/network/transfer_transport_test.dart
  test/app/realtime_feature_adapters_test.dart
  test/app/app_runtime_test.dart
)

echo "Client Network V2 coverage threshold: ${MINIMUM}%"
echo 'Client coverage scope: apps/ssh_mobile_full/lib/services/network/'
echo "Coverage artifacts: $RUN_DIR"
echo "Flutter runner: $FLUTTER_BIN"
echo "Tests: ${test_files[*]}"

coverage_arguments=()
for test_file in "${test_files[@]}"; do
  coverage_name="$(basename "${test_file%.dart}")-lcov.info"
  coverage_file="$RUN_DIR/$coverage_name"
  echo "Running isolated coverage: $test_file"
  coverage_status=0
  if env \
    XDG_CONFIG_HOME="$FLUTTER_CONFIG_ROOT" \
    HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= \
    ALL_PROXY= all_proxy= \
    SSH_MOBILE_WINDOWS_PROXY= \
    NO_PROXY=localhost,127.0.0.1,::1 \
    no_proxy=localhost,127.0.0.1,::1 \
    timeout "$FLUTTER_TIMEOUT" \
    "$FLUTTER_BIN" test --no-pub --no-test-assets \
      --coverage --coverage-path "$coverage_file" \
      --reporter expanded "$test_file"; then
    coverage_arguments+=("--file=$coverage_file")
  else
    coverage_status=$?
    if [[ "$coverage_status" == '124' || "$coverage_status" == '137' ]]; then
      echo "Flutter coverage timed out for $test_file; run this gate on Windows or CI with a working Flutter VM Service." >&2
    fi
    echo "Client Network V2 test failed: $test_file" >&2
    exit 1
  fi
done

dart run tool/check_coverage.dart \
  --minimum="$MINIMUM" \
  --details \
  "${coverage_arguments[@]}" \
  --include=lib/services/network/
