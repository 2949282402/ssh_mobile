#!/usr/bin/env bash

# Run the Linux-runnable CI gates locally from WSL.
#
# Configuration, runtime reporting, App jobs, and workspace/service jobs live
# in paired helper modules so this entrypoint remains easy to audit.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=full_test_runtime.sh
source "$SCRIPT_DIR/full_test_runtime.sh"
# shellcheck source=full_test_config.sh
source "$SCRIPT_DIR/full_test_config.sh"
# shellcheck source=full_test_runner.sh
source "$SCRIPT_DIR/full_test_runner.sh"
# shellcheck source=full_test_app.sh
source "$SCRIPT_DIR/full_test_app.sh"
# shellcheck source=full_test_jobs.sh
source "$SCRIPT_DIR/full_test_jobs.sh"

PRE_JOBS=(
  'front-quality:job_front'
  'admin-api-contract:job_admin_api_contract'
  'telemetry-contract:job_telemetry_contract'
  'native-network-quality:job_native'
  'sdk-dart-quality:job_sdk'
  'lan-network-v2-targeted:job_lan_network_v2'
  'relay-quality:job_relay'
  'protocol-v2-contract:job_protocol'
  'architecture-check:job_architecture'
  'app-static-quality:job_app_static'
)

if ((SKIP_BOOTSTRAP == 0)); then
  run_single bootstrap job_bootstrap
else
  printf '[SKIP] bootstrap (--no-bootstrap requested)\n\n'
fi

run_batch "${PRE_JOBS[@]}"

# Keep the Docker/client process pool independent from ordinary Flutter and
# package jobs. It is opt-in because building Relay + Front is intentionally
# slower than the daily component regression gate.
if ((WITH_CLIENT_BACKEND_SMOKE)) && should_run client-backend-smoke; then
  run_single client-backend-smoke job_client_backend_smoke
fi

# Each workspace job starts its own Melos/Flutter process pool. Running the two
# pools together makes Flutter contend for its startup lock in WSL and is
# slower than keeping the outer CI jobs parallel. Keep this pair deterministic
# while the independent gates above and below still use --jobs.
if should_run workspace-core-quality; then
  run_single workspace-core-quality job_core
fi
if should_run workspace-features-quality; then
  run_single workspace-features-quality job_features
fi

APP_JOBS=()
for ((shard = 0; shard < APP_SHARD_COUNT; shard++)); do
  APP_JOBS+=("app-unit-shard-$shard:job_app_unit_$shard")
done
if ((APP_SHARDS_PARALLEL)); then
  run_batch "${APP_JOBS[@]}"
else
  for spec in "${APP_JOBS[@]}"; do
    name="${spec%%:*}"
    function_name="${spec#*:}"
    if should_run "$name"; then
      run_single "$name" "$function_name"
    fi
  done
fi

run_batch 'android-build:job_android'

if should_run app-coverage; then
  if ((APP_COVERAGE_ENABLED == 0)); then
    if [[ -n "$ONLY_JOBS" ]]; then
      record_skip app-coverage 'Flutter coverage was not enabled for this explicit app-coverage selection. Use scripts/bash/coverage/client_coverage.sh or --with-coverage.'
    else
      printf '[SKIP] app-coverage (daily gate; run scripts/bash/coverage/client_coverage.sh for the periodic client review)\n\n'
    fi
  else
    all_app_shards_passed=1
    for ((shard = 0; shard < APP_SHARD_COUNT; shard++)); do
      if [[ "${RESULTS[app-unit-shard-$shard]:-1}" != 0 ]]; then
        all_app_shards_passed=0
        break
      fi
    done
    if ((all_app_shards_passed)); then
      run_single app-coverage job_app_coverage
    else
      record_skip app-coverage 'Full App coverage depends on every App test shard passing.'
    fi
  fi
fi

if [[ -z "$ONLY_JOBS" ]]; then
  printf '\nPlatform-only CI jobs not runnable from WSL/Linux:\n'
  printf '  [SKIP] terminal-smoke-build — Windows Flutter desktop toolchain\n'
  printf '  [SKIP] windows-build         — Windows Flutter desktop toolchain\n'
  printf '  [SKIP] macos-build            — macOS/Xcode toolchain\n'
  printf '  [SKIP] ios-build              — macOS/Xcode/CocoaPods toolchain\n'
fi

printf '\nFinal local CI summary:\n'
for name in "${SELECTED_NAMES[@]}"; do
  status="${RESULTS[$name]:-1}"
  duration="${DURATIONS[$name]:-0}"
  case "$status" in
    0) printf '  PASS %s (%ss)\n' "$name" "$duration" ;;
    "$SKIP_STATUS") printf '  GAP  %s (%ss)\n' "$name" "$duration" ;;
    *) printf '  FAIL %s (%ss; exit %s)\n' "$name" "$duration" "$status" ;;
  esac
done
RUN_END_SECONDS="$(date +%s)"
printf 'Total elapsed: %ss\n' "$((RUN_END_SECONDS - RUN_START_SECONDS))"
printf 'Raw logs: %s\n' "$LOG_DIR"

if ((OVERALL_FAILURE)); then
  exit 1
fi
if ((OVERALL_INCOMPLETE)); then
  exit 2
fi
exit 0
