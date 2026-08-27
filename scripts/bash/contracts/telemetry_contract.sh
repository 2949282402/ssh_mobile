#!/usr/bin/env bash

# Verify Telemetry Data Contracts across Go, Front (TypeScript), and Dart.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

for command_name in go npm flutter; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 69
  fi
done

echo "Validating Telemetry contracts..."

# 1. Go validation
(
  cd "$ROOT_DIR/relay"
  go test ./internal/telemetry -run '^TestTelemetryContract' -count=1
)

# 2. TypeScript / Front validation
(
  cd "$ROOT_DIR/front"
  npm run test:run -- src/schemas/telemetry-contract.test.ts
)

# 3. Dart validation
(
  cd "$ROOT_DIR"
  flutter test --no-pub packages/core/app_core/test/telemetry_contract_test.dart
)

echo "Telemetry Contract validation passed."
