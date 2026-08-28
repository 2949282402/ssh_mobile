#!/usr/bin/env bash

# CI job runner and reporting helpers. Sourced by full_test.sh; keep shared state in the aggregate.

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
