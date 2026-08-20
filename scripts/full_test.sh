#!/usr/bin/env bash

# Run the Linux-runnable GitHub Actions gates locally from WSL.
#
# Raw command output is kept in a per-job log. The terminal receives only
# failure/environment-gap summaries so an agent can inspect the signal first.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

SKIP_STATUS=125
# WSL measurements on 2026-08-20:
#   * architecture/core gates: about 5m45s
#   * feature gate serialised: about 4m07s (parallel Melos reached 8m35s)
#   * Full App shards: about 117s/102s when run one at a time
# Keep one Flutter test process active in this shared WSL workspace. Two App
# shards started together contend for build/test_cache and can stall before the
# first test loads, so App shard scheduling is serialized below.
DEFAULT_APP_TIMEOUT="${FULL_TEST_APP_TIMEOUT:-8m}"
DEFAULT_FLUTTER_CONCURRENCY="${FULL_TEST_FLUTTER_CONCURRENCY:-1}"
DEFAULT_MELOS_CONCURRENCY="${FULL_TEST_MELOS_CONCURRENCY:-1}"
DEFAULT_MELOS_TEST_CONCURRENCY="${FULL_TEST_MELOS_TEST_CONCURRENCY:-1}"
DEFAULT_APP_COVERAGE="${FULL_TEST_COVERAGE:-0}"
DEFAULT_WORKSPACE_TEST_TIMEOUT="${FULL_TEST_WORKSPACE_TEST_TIMEOUT:-5m}"

USER_HOME="${HOME:-}"
TOOLCHAIN_ROOT="${SSH_MOBILE_TOOLCHAIN_ROOT:-$USER_HOME/.local/ssh-mobile-toolchain}"
GO_ROOT="${SSH_MOBILE_GO_ROOT:-$TOOLCHAIN_ROOT/go1.27.0}"
WSL_TEMP_ROOT="${FULL_TEST_TMPDIR:-/tmp}"

JOB_LIMIT="${FULL_TEST_JOBS:-}"
FLUTTER_CONCURRENCY="$DEFAULT_FLUTTER_CONCURRENCY"
MELOS_CONCURRENCY="$DEFAULT_MELOS_CONCURRENCY"
MELOS_TEST_CONCURRENCY="$DEFAULT_MELOS_TEST_CONCURRENCY"
APP_TIMEOUT="$DEFAULT_APP_TIMEOUT"
APP_COVERAGE_ENABLED="$DEFAULT_APP_COVERAGE"
WORKSPACE_TEST_TIMEOUT="$DEFAULT_WORKSPACE_TEST_TIMEOUT"
FEATURE_LOOPBACK_ENABLED="${FULL_TEST_FEATURE_LOOPBACK:-0}"
SKIP_BOOTSTRAP=0
DOCKER_ENABLED=1
VERBOSE=0
ONLY_JOBS=""

usage() {
  cat <<'EOF'
Usage: bash scripts/full_test.sh [options]

Run the CI gates that are available in a WSL/Linux environment. Normal passing
output is kept in a log directory; failures and environment gaps are printed.

Options:
  --jobs N                  Maximum independent CI jobs running at once (default: 4).
  --serial                  Equivalent to --jobs 1.
  --flutter-concurrency N   Flutter test workers per App test process (default: 1).
  --melos-concurrency N     Workspace packages tested by Melos at once (default: 1).
  --melos-test-concurrency N
                            Test cases per workspace Flutter package (default: 1).
  --app-timeout DURATION    Timeout for one App test attempt (default: 8m).
  --with-coverage            Collect Flutter coverage and enforce the App coverage gate.
  --no-coverage              Skip Flutter coverage collection (default in WSL).
  --with-feature-loopback    Include MCP socket tests skipped by the WSL Flutter tester.
  --workspace-test-timeout DURATION
                            Timeout for one Melos package test process (default: 5m).
  --no-bootstrap            Do not run dependency installation first.
  --no-docker               Do not use Docker-backed CI checks.
  --only JOBS               Comma-separated job names to run.
  --verbose                 Print a short tail for successful jobs too.
  -h, --help                Show this help.

Examples:
  bash scripts/full_test.sh
  bash scripts/full_test.sh --jobs 4 --flutter-concurrency 4
  bash scripts/full_test.sh --no-coverage --jobs 4
  bash scripts/full_test.sh --only protocol-v2-contract,architecture-check
  FULL_TEST_APP_TIMEOUT=8m bash scripts/full_test.sh --serial

Exit status:
  0  All selected checks passed.
  1  A selected check failed.
  2  Checks were incomplete because a required local environment capability
     was unavailable (for example Docker or a platform-only toolchain).
EOF
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while (($# > 0)); do
  case "$1" in
    --jobs)
      (($# >= 2)) || { echo "--jobs requires a value" >&2; exit 64; }
      JOB_LIMIT="$2"
      shift 2
      ;;
    --jobs=*)
      JOB_LIMIT="${1#*=}"
      shift
      ;;
    --serial)
      JOB_LIMIT=1
      shift
      ;;
    --flutter-concurrency)
      (($# >= 2)) || { echo "--flutter-concurrency requires a value" >&2; exit 64; }
      FLUTTER_CONCURRENCY="$2"
      shift 2
      ;;
    --flutter-concurrency=*)
      FLUTTER_CONCURRENCY="${1#*=}"
      shift
      ;;
    --melos-concurrency)
      (($# >= 2)) || { echo "--melos-concurrency requires a value" >&2; exit 64; }
      MELOS_CONCURRENCY="$2"
      shift 2
      ;;
    --melos-concurrency=*)
      MELOS_CONCURRENCY="${1#*=}"
      shift
      ;;
    --melos-test-concurrency)
      (($# >= 2)) || { echo "--melos-test-concurrency requires a value" >&2; exit 64; }
      MELOS_TEST_CONCURRENCY="$2"
      shift 2
      ;;
    --melos-test-concurrency=*)
      MELOS_TEST_CONCURRENCY="${1#*=}"
      shift
      ;;
    --app-timeout)
      (($# >= 2)) || { echo "--app-timeout requires a value" >&2; exit 64; }
      APP_TIMEOUT="$2"
      shift 2
      ;;
    --app-timeout=*)
      APP_TIMEOUT="${1#*=}"
      shift
      ;;
    --with-coverage)
      APP_COVERAGE_ENABLED=1
      shift
      ;;
    --no-coverage)
      APP_COVERAGE_ENABLED=0
      shift
      ;;
    --with-feature-loopback)
      FEATURE_LOOPBACK_ENABLED=1
      shift
      ;;
    --workspace-test-timeout)
      (($# >= 2)) || { echo "--workspace-test-timeout requires a value" >&2; exit 64; }
      WORKSPACE_TEST_TIMEOUT="$2"
      shift 2
      ;;
    --workspace-test-timeout=*)
      WORKSPACE_TEST_TIMEOUT="${1#*=}"
      shift
      ;;
    --no-bootstrap)
      SKIP_BOOTSTRAP=1
      shift
      ;;
    --no-docker)
      DOCKER_ENABLED=0
      shift
      ;;
    --only)
      (($# >= 2)) || { echo "--only requires a value" >&2; exit 64; }
      ONLY_JOBS="$2"
      shift 2
      ;;
    --only=*)
      ONLY_JOBS="${1#*=}"
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$JOB_LIMIT" ]]; then
  CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  if ! is_positive_int "$CPU_COUNT"; then
    CPU_COUNT=2
  fi
  JOB_LIMIT=$((CPU_COUNT < 4 ? CPU_COUNT : 4))
fi

if ! is_positive_int "$JOB_LIMIT"; then
  echo "--jobs must be a positive integer: $JOB_LIMIT" >&2
  exit 64
fi
if ! is_positive_int "$FLUTTER_CONCURRENCY"; then
  echo "--flutter-concurrency must be a positive integer: $FLUTTER_CONCURRENCY" >&2
  exit 64
fi
if ! is_positive_int "$MELOS_CONCURRENCY"; then
  echo "--melos-concurrency must be a positive integer: $MELOS_CONCURRENCY" >&2
  exit 64
fi
if ! is_positive_int "$MELOS_TEST_CONCURRENCY"; then
  echo "--melos-test-concurrency must be a positive integer: $MELOS_TEST_CONCURRENCY" >&2
  exit 64
fi
if [[ ! "$APP_TIMEOUT" =~ ^[0-9]+[smhd]$ ]]; then
  echo "--app-timeout must look like 60s, 20m, or 1h: $APP_TIMEOUT" >&2
  exit 64
fi
if [[ "$APP_COVERAGE_ENABLED" != 0 && "$APP_COVERAGE_ENABLED" != 1 ]]; then
  echo "FULL_TEST_COVERAGE/coverage option must be 0 or 1: $APP_COVERAGE_ENABLED" >&2
  exit 64
fi
if [[ "$FEATURE_LOOPBACK_ENABLED" != 0 && "$FEATURE_LOOPBACK_ENABLED" != 1 ]]; then
  echo "FULL_TEST_FEATURE_LOOPBACK/loopback option must be 0 or 1: $FEATURE_LOOPBACK_ENABLED" >&2
  exit 64
fi
if [[ ! "$WORKSPACE_TEST_TIMEOUT" =~ ^[0-9]+[smhd]$ ]]; then
  echo "--workspace-test-timeout must look like 60s, 5m, or 1h: $WORKSPACE_TEST_TIMEOUT" >&2
  exit 64
fi

# Prefer the Linux toolchain installed for this WSL workspace when it exists.
for candidate in \
  "$TOOLCHAIN_ROOT/protobuf/bin" \
  "$TOOLCHAIN_ROOT/flutter/bin" \
  "$TOOLCHAIN_ROOT/flutter/bin/cache/dart-sdk/bin" \
  "$USER_HOME/.pub-cache/bin" \
  "$USER_HOME/.go/bin" \
  "$USER_HOME/go/bin" \
  "$USER_HOME/.cargo/bin"; do
  if [[ -d "$candidate" ]]; then
    PATH="$candidate:$PATH"
  fi
done
if [[ -d "$USER_HOME/.nvm/versions/node" ]]; then
  for candidate in "$USER_HOME"/.nvm/versions/node/*/bin; do
    if [[ -d "$candidate" ]]; then
      PATH="$candidate:$PATH"
    fi
  done
fi
if [[ -d "$GO_ROOT" ]]; then
  PATH="$GO_ROOT/bin:$PATH"
  export GOROOT="$GO_ROOT"
fi
export PATH

if [[ -z "${JAVA_HOME:-}" && -d "$TOOLCHAIN_ROOT/jdk-17" ]]; then
  export JAVA_HOME="$TOOLCHAIN_ROOT/jdk-17"
fi
if [[ -z "${ANDROID_HOME:-}" && -d "$TOOLCHAIN_ROOT/android-sdk" ]]; then
  export ANDROID_HOME="$TOOLCHAIN_ROOT/android-sdk"
fi

# Flutter's local HTTP tests need both proxy variable spellings to bypass the
# WSL loopback proxy. Preserve any user-provided entries.
LOOPBACK_NO_PROXY="127.0.0.1,localhost,::1"
if [[ -n "${NO_PROXY:-}" ]]; then
  NO_PROXY="$NO_PROXY,$LOOPBACK_NO_PROXY"
else
  NO_PROXY="$LOOPBACK_NO_PROXY"
fi
export NO_PROXY
export no_proxy="$NO_PROXY"

# Keep Flutter/Dart/Rust/Node temporary files on the Linux filesystem. WSL can
# inherit TMP/TEMP from Windows, which makes test subprocesses cross the
# /mnt/c boundary and can break loopback HTTP startup under load.
if [[ ! -d "$WSL_TEMP_ROOT" || ! -w "$WSL_TEMP_ROOT" ]]; then
  echo "WSL temporary directory is unavailable or not writable: $WSL_TEMP_ROOT" >&2
  exit 69
fi
export TMPDIR="$WSL_TEMP_ROOT"
export TMP="$WSL_TEMP_ROOT"
export TEMP="$WSL_TEMP_ROOT"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
if [[ -n "${FULL_TEST_LOG_DIR:-}" ]]; then
  LOG_DIR="${FULL_TEST_LOG_DIR%/}/$RUN_ID"
  mkdir -p "$LOG_DIR"
else
  LOG_DIR="$(mktemp -d "$WSL_TEMP_ROOT/ssh-mobile-full-test.XXXXXX")"
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "rg is required for compact failure filtering; install ripgrep first." >&2
  exit 69
fi

DOCKER_AVAILABLE=0
if ((DOCKER_ENABLED)) && command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    DOCKER_AVAILABLE=1
  fi
fi

printf 'SSH Mobile local CI\n'
printf 'root: %s\n' "$ROOT_DIR"
printf 'parallel jobs: %s; Flutter workers per App process: %s\n' "$JOB_LIMIT" "$FLUTTER_CONCURRENCY"
printf 'Melos package concurrency: %s\n' "$MELOS_CONCURRENCY"
printf 'Melos test-case concurrency: %s\n' "$MELOS_TEST_CONCURRENCY"
printf 'App test attempt timeout: %s\n' "$APP_TIMEOUT"
printf 'App coverage: %s\n' "$([[ $APP_COVERAGE_ENABLED -eq 1 ]] && echo enabled || echo disabled)"
printf 'Workspace package test timeout: %s\n' "$WORKSPACE_TEST_TIMEOUT"
printf 'Feature loopback tests: %s\n' "$([[ $FEATURE_LOOPBACK_ENABLED -eq 1 ]] && echo enabled || echo skipped-for-WSL)"
printf 'Docker-backed checks: %s\n' "$([[ $DOCKER_AVAILABLE -eq 1 ]] && echo available || echo unavailable)"
printf 'logs: %s\n\n' "$LOG_DIR"

declare -a SELECTED_NAMES=()
declare -A RESULTS=()
declare -A LOG_PATHS=()
declare -A DURATIONS=()
OVERALL_FAILURE=0
OVERALL_INCOMPLETE=0
RUN_START_SECONDS="$(date +%s)"

step() {
  local label="$1"
  shift
  printf '\n== %s ==\n' "$label"
  "$@"
}

run_in() {
  local relative_dir="$1"
  shift
  (cd "$ROOT_DIR/$relative_dir" && "$@")
}

need() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "ENVIRONMENT GAP: required command is unavailable: $command_name"
      return "$SKIP_STATUS"
    fi
  done
}

should_run() {
  local name="$1"
  if [[ -z "$ONLY_JOBS" ]]; then
    return 0
  fi

  local requested
  IFS=',' read -r -a requested_jobs <<< "$ONLY_JOBS"
  for requested in "${requested_jobs[@]}"; do
    if [[ "$requested" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

clean_log() {
  local input="$1"
  local output="$2"
  # Remove common ANSI terminal controls and make Flutter progress readable.
  sed -E $'s/\033\\[[0-9;?]*[ -\/]*[@-~]//g' "$input" | tr '\r' '\n' > "$output"
}

show_log_findings() {
  local name="$1"
  local log="${LOG_PATHS[$name]}"
  local cleaned="$LOG_DIR/$name.cleaned.log"
  clean_log "$log" "$cleaned"

  local findings
  findings="$(rg -n -i --no-heading \
    -e 'FAIL|FAILED|ERROR|Error:|Exception|panic|fatal|timed out|timeout|permission denied|not found|operation not permitted|socketexception|assert(ion)?|vulnerab|non-zero|unhandled|segmentation fault|could not|unable to|environment gap' \
    "$cleaned" || true)"
  findings="$(printf '%s\n' "$findings" | rg -v -i \
    -e 'All tests passed|No issues found|test result: ok|[0-9]+ passed; 0 failed|^ok([[:space:]]|$)|^PASS$|^\+[0-9]+:|loading /|Compiling |Built |Building |Downloading |Resolving dependencies|Got dependencies|Changed [0-9]+ dependencies|^✓' || true)"
  findings="$(printf '%s\n' "$findings" | rg -v -i \
    -e '^\[DeviceNameUtil\] Failed to get device name: MissingPluginException' \
    -e '^Waiting for another flutter command to release the startup lock' || true)"

  if [[ -n "$findings" ]]; then
    printf '%s\n' "$findings" | tail -n 80
  else
    printf 'No known failure marker found; last log lines:\n'
    tail -n 30 "$cleaned"
  fi
}

report_job() {
  local name="$1"
  local status_file="$LOG_DIR/$name.status"
  local status=1
  if [[ -s "$status_file" ]]; then
    status="$(<"$status_file")"
  fi
  local duration=0
  if [[ -s "$LOG_DIR/$name.duration" ]]; then
    duration="$(<"$LOG_DIR/$name.duration")"
  fi
  RESULTS["$name"]="$status"
  LOG_PATHS["$name"]="$LOG_DIR/$name.log"
  DURATIONS["$name"]="$duration"

  case "$status" in
    0)
      printf '[PASS] %s (%ss)\n' "$name" "$duration"
      if ((VERBOSE)); then
        local cleaned="$LOG_DIR/$name.cleaned.log"
        clean_log "${LOG_PATHS[$name]}" "$cleaned"
        tail -n 20 "$cleaned"
      fi
      ;;
    "$SKIP_STATUS")
      OVERALL_INCOMPLETE=1
      printf '[GAP ] %s (%ss; environment/dependency gap)\n' "$name" "$duration"
      show_log_findings "$name"
      ;;
    *)
      OVERALL_FAILURE=1
      printf '[FAIL] %s (%ss; exit %s)\n' "$name" "$duration" "$status"
      show_log_findings "$name"
      ;;
  esac
}

run_job_process() {
  local name="$1"
  local function_name="$2"
  local log="$LOG_DIR/$name.log"
  local status_file="$LOG_DIR/$name.status"
  local duration_file="$LOG_DIR/$name.duration"
  local started_at ended_at

  : > "$log"
  started_at="$(date +%s)"
  set +e
  (set -Eeuo pipefail; "$function_name") > "$log" 2>&1
  local status=$?
  ended_at="$(date +%s)"
  printf '%s\n' "$status" > "$status_file"
  printf '%s\n' "$((ended_at - started_at))" > "$duration_file"
  return 0
}

run_single() {
  local name="$1"
  local function_name="$2"
  SELECTED_NAMES+=("$name")
  printf '[RUN ] %s\n' "$name"
  run_job_process "$name" "$function_name" &
  local pid=$!
  wait "$pid" || true
  report_job "$name"
}

run_batch() {
  local -a specs=("$@")
  local -a selected_specs=()
  local spec selected_name
  for spec in "${specs[@]}"; do
    selected_name="${spec%%:*}"
    if should_run "$selected_name"; then
      selected_specs+=("$spec")
    fi
  done

  local offset=0
  local total="${#selected_specs[@]}"

  while ((offset < total)); do
    local -a pids=()
    local -a names=()
    local end=$((offset + JOB_LIMIT))
    if ((end > total)); then
      end=$total
    fi

    local index name function_name
    for ((index = offset; index < end; index++)); do
      spec="${selected_specs[$index]}"
      name="${spec%%:*}"
      function_name="${spec#*:}"
      SELECTED_NAMES+=("$name")
      names+=("$name")
      printf '[RUN ] %s\n' "$name"
      run_job_process "$name" "$function_name" &
      pids+=("$!")
    done

    local pid
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
    for name in "${names[@]}"; do
      report_job "$name"
    done
    offset=$end
  done
}

record_skip() {
  local name="$1"
  local reason="$2"
  SELECTED_NAMES+=("$name")
  printf '%s\n' "ENVIRONMENT GAP: $reason" > "$LOG_DIR/$name.log"
  printf '%s\n' "$SKIP_STATUS" > "$LOG_DIR/$name.status"
  printf '0\n' > "$LOG_DIR/$name.duration"
  report_job "$name"
}

job_app_static() {
  need dart flutter || return "$SKIP_STATUS"
  step 'Check generated app icons' bash -c 'cd apps/ssh_mobile_full && dart run tool/generate_app_icons.dart && git diff --exit-code -- assets android ios macos web windows/runner/resources/app_icon.ico'
  step 'Check Full App formatting' run_in apps/ssh_mobile_full dart format --output=none --set-exit-if-changed lib test tool
  step 'Check generated database code' bash -c 'cd apps/ssh_mobile_full && dart run build_runner build && git diff --exit-code -- lib/data/database/app_database.g.dart'
  step 'Security regression grep' bash -c 'cd apps/ssh_mobile_full && ! grep -R "SshIdentityCache" lib && ! grep -R "reconnectCredentials" lib && ! grep -R "privateKeyDigest" lib'
  step 'Analyze Full App' run_in apps/ssh_mobile_full flutter analyze --no-fatal-infos
}

collect_app_tests() {
  local -n output_array="$1"
  mapfile -d '' all_test_files < <(find "$ROOT_DIR/apps/ssh_mobile_full/test" -type f -name '*_test.dart' -print0 | sort -z)
  local test_file
  for test_file in "${all_test_files[@]}"; do
    test_file="${test_file#"$ROOT_DIR/apps/ssh_mobile_full/"}"
    case "$test_file" in
      test/features/startup/views/startup_screen_test.dart|test/screens/system_admin/system_admin_snapshot_tabs_test.dart|test/services/network/transfer_transport_test.dart)
        ;;
      *)
        output_array+=("$test_file")
        ;;
    esac
  done
}

run_app_test_with_retry() {
  local shard="$1"
  local coverage_path="$2"
  shift 2
  local attempt status
  local -a coverage_args=()
  if ((APP_COVERAGE_ENABLED)); then
    coverage_args=(--coverage --coverage-path "$coverage_path")
  fi
  for attempt in 1 2; do
    if ((APP_COVERAGE_ENABLED)); then
      rm -f "$coverage_path"
    fi
    printf 'Running App shard %s (attempt %s) with Flutter concurrency %s.\n' "$shard" "$attempt" "$FLUTTER_CONCURRENCY"
    if timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
      flutter test --no-pub --no-test-assets "${coverage_args[@]}" \
      --reporter compact --fail-fast --timeout 60s \
      --concurrency "$FLUTTER_CONCURRENCY" \
      --total-shards 2 --shard-index "$shard" "$@"; then
      return 0
    else
      status=$?
    fi
    if ((attempt == 2)); then
      return "$status"
    fi
    echo 'Flutter App shard failed or timed out; retrying once.'
  done
}

job_app_unit() {
  local shard="$1"
  need flutter || return "$SKIP_STATUS"
  local -a coverage_test_files=()
  collect_app_tests coverage_test_files
  if ((${#coverage_test_files[@]} == 0)); then
    echo 'No Full App coverage test files were discovered.'
    return 1
  fi

  local coverage_dir="$LOG_DIR/coverage/full-test-shard-$shard"
  mkdir -p "$coverage_dir"
  run_in apps/ssh_mobile_full run_app_test_with_retry "$shard" "$coverage_dir/lcov.info" "${coverage_test_files[@]}"
  local test_status=$?
  if ((test_status != 0)); then
    return "$test_status"
  fi

  local isolated_startup="$coverage_dir/isolated-startup-lcov.info"
  local isolated_system_admin="$coverage_dir/isolated-system-admin-lcov.info"
  local non_coverage_file='test/services/network/transfer_transport_test.dart'
  local -a startup_coverage_args=()
  local -a system_admin_coverage_args=()
  if ((APP_COVERAGE_ENABLED)); then
    rm -f "$isolated_startup" "$isolated_system_admin"
    startup_coverage_args=(--coverage --coverage-path "$isolated_startup")
    system_admin_coverage_args=(--coverage --coverage-path "$isolated_system_admin")
  fi
  step "Run isolated startup test for shard $shard" run_in apps/ssh_mobile_full timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
    flutter test --no-pub --no-test-assets "${startup_coverage_args[@]}" --reporter compact --fail-fast \
    --timeout 60s --concurrency "$FLUTTER_CONCURRENCY" --total-shards 2 --shard-index "$shard" \
    test/features/startup/views/startup_screen_test.dart
  step "Run isolated system-admin test for shard $shard" run_in apps/ssh_mobile_full timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
    flutter test --no-pub --no-test-assets "${system_admin_coverage_args[@]}" --reporter compact --fail-fast \
    --timeout 60s --concurrency "$FLUTTER_CONCURRENCY" --total-shards 2 --shard-index "$shard" \
    test/screens/system_admin/system_admin_snapshot_tabs_test.dart
  step "Run native transfer test for shard $shard" run_in apps/ssh_mobile_full timeout --signal=TERM --kill-after=30s "$APP_TIMEOUT" \
    flutter test --no-pub --no-test-assets --reporter compact --fail-fast --timeout 60s --concurrency "$FLUTTER_CONCURRENCY" \
    --total-shards 2 --shard-index "$shard" "$non_coverage_file"
}

job_app_unit_0() { job_app_unit 0; }
job_app_unit_1() { job_app_unit 1; }

job_app_coverage() {
  need dart || return "$SKIP_STATUS"
  local -a coverage_args=()
  local shard isolated
  for shard in 0 1; do
    coverage_args+=("--file=$LOG_DIR/coverage/full-test-shard-$shard/lcov.info")
    for isolated in startup system-admin; do
      coverage_args+=("--file=$LOG_DIR/coverage/full-test-shard-$shard/isolated-$isolated-lcov.info")
    done
  done
  step 'Enforce Full App shard coverage' run_in apps/ssh_mobile_full dart run tool/check_coverage.dart --minimum=35 "${coverage_args[@]}"
}

job_android() {
  need flutter || return "$SKIP_STATUS"
  local android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -n "$android_sdk" && ! -d "$android_sdk/platforms/android-36" ]]; then
    echo "ENVIRONMENT GAP: Flutter 3.47.0 requires $android_sdk/platforms/android-36; install platforms;android-36."
    return "$SKIP_STATUS"
  fi
  step 'Build Android debug APK' run_in apps/ssh_mobile_full flutter build apk --debug --no-pub
}

job_bootstrap() {
  need dart flutter npm cargo go python3 || return "$SKIP_STATUS"
  step 'Install root Dart workspace dependencies' dart pub get
  step 'Install native Flutter package dependencies' run_in packages/infrastructure/ssh_mobile_network_native flutter pub get
  step 'Install Full App dependencies' run_in apps/ssh_mobile_full flutter pub get
  step 'Install front dependencies' run_in front npm ci
  step 'Fetch locked Rust dependencies' run_in native/network_core cargo fetch --locked
  step 'Fetch Go dependencies' run_in relay go mod download
}

job_front() {
  need npm || return "$SKIP_STATUS"
  step 'Typecheck front' run_in front npm run typecheck
  step 'Lint front' run_in front npm run lint
  step 'Test front' run_in front npm run test:run
  step 'Build front' run_in front npm run build
  if ((DOCKER_AVAILABLE)); then
    step 'Build front container' docker build -t "ssh-mobile-relay-front:full-test-$RUN_ID" "$ROOT_DIR/front"
  else
    echo 'ENVIRONMENT GAP: Docker daemon is unavailable; front container build was not run.'
    return "$SKIP_STATUS"
  fi
}

job_native() {
  need cargo || return "$SKIP_STATUS"
  step 'Check Rust formatting' run_in native/network_core cargo fmt --all -- --check

  local turn_ready=0
  COTURN_CONTAINER="ssh-mobile-full-test-coturn-$RUN_ID"
  if ((DOCKER_AVAILABLE)); then
    if docker run -d --rm --name "$COTURN_CONTAINER" --network host \
      coturn/coturn:4.6.3 -n --log-file=stdout --lt-cred-mech \
      --fingerprint --user test:test --realm=ssh-mobile.test \
      --no-tls --no-dtls --min-port=49160 --max-port=49200 \
      --no-multicast-peers >/dev/null; then
      turn_ready=1
      trap 'docker rm -f "$COTURN_CONTAINER" >/dev/null 2>&1 || true' EXIT
    else
      echo 'ENVIRONMENT GAP: coturn container could not be started; TURN fallback was not run.'
    fi
  else
    echo 'ENVIRONMENT GAP: Docker daemon is unavailable; TURN fallback was not run.'
  fi

  step 'Test Rust workspace' run_in native/network_core cargo test --workspace --locked
  if ((turn_ready)); then
    step 'Test WebRTC TURN fallback' run_in native/network_core cargo test -p network-webrtc --locked -- --ignored relay_only_drivers_exchange_data_channel_payloads
  fi
  step 'Lint Rust workspace' run_in native/network_core cargo clippy --workspace --all-targets --locked -- -D warnings

  if ((turn_ready == 0)); then
    return "$SKIP_STATUS"
  fi
}

wait_for_mysql() {
  local attempt
  for attempt in $(seq 1 60); do
    if docker exec "$RELAY_MYSQL_CONTAINER" mysqladmin ping -h 127.0.0.1 -urelay -prelay >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_redis() {
  local attempt
  for attempt in $(seq 1 30); do
    if docker exec "$RELAY_REDIS_CONTAINER" redis-cli ping 2>/dev/null | rg -q '^PONG$'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_relay_services() {
  RELAY_MYSQL_CONTAINER="ssh-mobile-full-test-mysql-$RUN_ID"
  RELAY_REDIS_CONTAINER="ssh-mobile-full-test-redis-$RUN_ID"
  trap 'docker rm -f "${RELAY_MYSQL_CONTAINER:-}" "${RELAY_REDIS_CONTAINER:-}" >/dev/null 2>&1 || true' EXIT

  docker run -d --rm --name "$RELAY_MYSQL_CONTAINER" -p 127.0.0.1::3306 \
    -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=relay \
    -e MYSQL_USER=relay -e MYSQL_PASSWORD=relay mysql:8.4 >/dev/null || return 1
  docker run -d --rm --name "$RELAY_REDIS_CONTAINER" -p 127.0.0.1::6379 \
    redis:7-alpine >/dev/null || return 1

  RELAY_MYSQL_PORT="$(docker port "$RELAY_MYSQL_CONTAINER" 3306/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  RELAY_REDIS_PORT="$(docker port "$RELAY_REDIS_CONTAINER" 6379/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  [[ "$RELAY_MYSQL_PORT" =~ ^[0-9]+$ && "$RELAY_REDIS_PORT" =~ ^[0-9]+$ ]] || return 1

  wait_for_mysql || return 1
  wait_for_redis || return 1
  export RELAY_TEST_MYSQL_DSN="relay:relay@tcp(127.0.0.1:${RELAY_MYSQL_PORT})/relay?parseTime=true&loc=UTC"
  export RELAY_TEST_REDIS_URL="redis://127.0.0.1:${RELAY_REDIS_PORT}/0"
}

job_relay() {
  need go || return "$SKIP_STATUS"
  local storage_ready=0
  if [[ -n "${RELAY_TEST_MYSQL_DSN:-}" && -n "${RELAY_TEST_REDIS_URL:-}" ]]; then
    storage_ready=1
    echo 'Using caller-provided Relay MySQL/Redis test endpoints.'
  elif ((DOCKER_AVAILABLE)); then
    if start_relay_services; then
      storage_ready=1
      trap 'docker rm -f "${RELAY_MYSQL_CONTAINER:-}" "${RELAY_REDIS_CONTAINER:-}" >/dev/null 2>&1 || true' EXIT
    else
      echo 'ENVIRONMENT GAP: MySQL/Redis test containers could not be started; storage integration tests were not run.'
    fi
  else
    echo 'ENVIRONMENT GAP: Docker daemon is unavailable; MySQL/Redis integration tests were not run.'
  fi

  step 'Check Go formatting' bash -c 'files="$(gofmt -l .)"; if [[ -n "$files" ]]; then printf "%s\n" "$files"; exit 1; fi'
  step 'Test relay' run_in relay go test ./...
  step 'Test relay with race detector' run_in relay go test -race ./...
  step 'Vet relay' run_in relay go vet ./...
  step 'Scan relay vulnerabilities' run_in relay go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...

  if ((storage_ready == 0)); then
    return "$SKIP_STATUS"
  fi
}

job_protocol() {
  need bash cargo go python3 protoc buf || return "$SKIP_STATUS"
  step 'Compile-check Network V2 protos' protoc --proto_path=protocol \
    --descriptor_set_out="$LOG_DIR/network-v2-$RUN_ID.desc" \
    protocol/proto/relay/v2/relay_v2.proto \
    protocol/proto/network/v2/network.proto
  step 'Run Relay V2 contract check' bash scripts/relay_v2_contract.sh
  step 'Run strict Network V2 acceptance gate' bash scripts/network_v2_acceptance.sh strict
  step 'buf lint' run_in protocol buf lint
  step 'buf breaking against frozen Relay V2' run_in protocol buf breaking . \
    --against '../.git#ref=6ec194bb3a66a748215d3abc11d6da84bd329619,subdir=protocol' \
    --path proto/relay/v2/relay_v2.proto
}

melos_exec() {
  local command="$1"
  shift
  dart run melos exec --concurrency "$MELOS_CONCURRENCY" --fail-fast "$@" -- "$command"
}

melos_feature_tests() {
  local exclusions=''
  if ((FEATURE_LOOPBACK_ENABLED == 0)); then
    exclusions=" ! -path 'test/services/mcp/mcp_http_server_test.dart'"
    exclusions+=" ! -path 'test/services/mcp/mcp_server_controller_test.dart'"
    exclusions+=" ! -path 'test/services/mcp/mcp_port_probe_test.dart'"
  fi
  local command="test_files=\$(find test -type f -name '*_test.dart'${exclusions} -print | sort);"
  command+=" timeout --signal=TERM --kill-after=20s $WORKSPACE_TEST_TIMEOUT"
  command+=" flutter test --no-pub --no-test-assets --concurrency $MELOS_TEST_CONCURRENCY \$test_files"
  dart run melos exec --concurrency "$MELOS_CONCURRENCY" --fail-fast "$@" -- "$command"
}

job_architecture() {
  need dart || return "$SKIP_STATUS"
  step 'Check agent documentation' dart run tool/check_agent_docs.dart
  step 'Test agent documentation checker' dart run test/tool/agent_docs_check_test.dart
  step 'Test CI workflow contract' dart run test/tool/ci_workflow_test.dart
  step 'Check architecture guard' dart run tool/architecture_check.dart
  step 'Check module dependencies' dart run tool/check_module_dependencies.dart
  step 'Check resource owners' dart run tool/check_resource_owners.dart
  step 'Check compatibility import inventory' dart run tool/compatibility_check.dart
  step 'Check duplicate implementations' dart run tool/duplicate_implementation_check.dart
}

job_sdk() {
  need dart || return "$SKIP_STATUS"
  step 'Format SDK packages' melos_exec 'dart format --output=none --set-exit-if-changed lib test' \
    --scope=network_sdk \
    --scope=network_transport \
    --scope=ssh_mobile_network_native
  step 'Analyze SDK packages' melos_exec 'flutter analyze --no-fatal-infos --no-pub' \
    --scope=network_sdk \
    --scope=network_transport \
    --scope=ssh_mobile_network_native
  step 'Test SDK packages' melos_exec "flutter test --no-pub --concurrency $MELOS_TEST_CONCURRENCY" \
    --scope=network_sdk \
    --scope=network_transport \
    --scope=ssh_mobile_network_native
}

job_core() {
  need dart || return "$SKIP_STATUS"
  step 'Format core packages' melos_exec 'dart format --output=none --set-exit-if-changed lib test' \
    --scope=app_core \
    --scope=app_ui \
    --scope=connection_core \
    --scope=ssh_core
  step 'Analyze core packages' melos_exec 'flutter analyze --no-fatal-infos --no-pub' \
    --scope=app_core \
    --scope=app_ui \
    --scope=connection_core \
    --scope=ssh_core
  step 'Test core packages' melos_exec "flutter test --no-pub --concurrency $MELOS_TEST_CONCURRENCY" \
    --scope=app_core \
    --scope=app_ui \
    --scope=connection_core \
    --scope=ssh_core
}

job_features() {
  need dart || return "$SKIP_STATUS"
  step 'Format feature packages' melos_exec 'dart format --output=none --set-exit-if-changed lib test' \
    --scope=feature_ai \
    --scope=feature_connection \
    --scope=feature_developer \
    --scope=feature_lan_share \
    --scope=feature_mcp \
    --scope=feature_monitoring \
    --scope=feature_playbook \
    --scope=feature_rag \
    --scope=feature_sftp \
    --scope=feature_system_admin \
    --scope=feature_terminal \
    --scope=feature_webview
  step 'Analyze feature packages' melos_exec 'flutter analyze --no-fatal-infos --no-pub' \
    --scope=feature_ai \
    --scope=feature_connection \
    --scope=feature_developer \
    --scope=feature_lan_share \
    --scope=feature_mcp \
    --scope=feature_monitoring \
    --scope=feature_playbook \
    --scope=feature_rag \
    --scope=feature_sftp \
    --scope=feature_system_admin \
    --scope=feature_terminal \
    --scope=feature_webview
  step 'Test feature packages' melos_feature_tests \
    --scope=feature_ai \
    --scope=feature_connection \
    --scope=feature_developer \
    --scope=feature_lan_share \
    --scope=feature_mcp \
    --scope=feature_monitoring \
    --scope=feature_playbook \
    --scope=feature_rag \
    --scope=feature_sftp \
    --scope=feature_system_admin \
    --scope=feature_terminal \
    --scope=feature_webview
  if ((FEATURE_LOOPBACK_ENABLED == 0)); then
    echo 'ENVIRONMENT GAP: Flutter tester cannot bind dart:io loopback sockets in this WSL toolchain; MCP HTTP/port/controller tests were not run.'
    return "$SKIP_STATUS"
  fi
}

PRE_JOBS=(
  'front-quality:job_front'
  'native-network-quality:job_native'
  'sdk-dart-quality:job_sdk'
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

APP_JOBS=(
  'app-unit-shard-0:job_app_unit_0'
  'app-unit-shard-1:job_app_unit_1'
)
# The two App shards intentionally share one Flutter build/test cache in this
# WSL checkout. Running them concurrently can leave both frontend servers in
# the loading phase indefinitely; CI matrix jobs remain parallel on isolated
# runners. Keep local App shards deterministic while preserving parallelism for
# independent Linux gates.
if should_run app-unit-shard-0; then
  run_single app-unit-shard-0 job_app_unit_0
fi
if should_run app-unit-shard-1; then
  run_single app-unit-shard-1 job_app_unit_1
fi

run_batch 'android-build:job_android'

if should_run app-coverage; then
  if ((APP_COVERAGE_ENABLED == 0)); then
    if [[ -n "$ONLY_JOBS" ]]; then
      record_skip app-coverage 'Flutter coverage was disabled; rerun with --with-coverage to enforce the App coverage gate.'
    else
      printf '[SKIP] app-coverage (--no-coverage requested; use --with-coverage to enforce the App coverage gate)\n\n'
    fi
  elif [[ "${RESULTS[app-unit-shard-0]:-1}" == 0 && "${RESULTS[app-unit-shard-1]:-1}" == 0 ]]; then
    run_single app-coverage job_app_coverage
  else
    record_skip app-coverage 'Full App coverage depends on both App test shards passing.'
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
