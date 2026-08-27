#!/usr/bin/env bash

# Verify Telemetry Data Contracts across Go, Front (TypeScript), and Dart.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

for command_name in dart go npm flutter; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 69
  fi
done

echo "Validating Telemetry contracts..."

# 1. Regenerate contract artifacts from the YAML source of truth, then verify
#    byte-for-byte that the generated artifacts are fresh (no drift).
(
  cd "$ROOT_DIR"
  dart run tool/gen_telemetry_contract.dart
  dart run tool/check_telemetry_contract_generated.dart
  dart run tool/check_telemetry_producers.dart
  dart run test/tool/telemetry_producer_ban_test.dart
)

# 2. Go validation
(
  cd "$ROOT_DIR/relay"
  go test ./internal/telemetry -run '^TestTelemetryContract' -count=1
)

# 3. TypeScript / Front validation
(
  cd "$ROOT_DIR/front"
  npm run test:run -- src/schemas/telemetry-contract.test.ts
)

# 4. Dart validation
(
  cd "$ROOT_DIR"
  flutter test --no-pub packages/core/app_core/test/telemetry_contract_test.dart
)

echo "Telemetry Contract validation passed."
