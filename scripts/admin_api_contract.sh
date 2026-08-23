#!/usr/bin/env bash

# Verify the real Go administrator handlers against the production Front Zod
# schemas without persisting response fixtures or sensitive runtime values.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssh-mobile-admin-contract.XXXXXX")"
FIXTURE_FILE="$RUN_DIR/admin-api.json"
CONTRACT_GOCACHE="${SSH_MOBILE_CONTRACT_GOCACHE:-${TMPDIR:-/tmp}/ssh-mobile-admin-contract-go-cache}"

cleanup() {
  rm -f "$FIXTURE_FILE"
  rmdir "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

for command_name in go npm; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 69
  fi
done

(
  cd "$ROOT_DIR/relay"
  GOCACHE="$CONTRACT_GOCACHE" \
    SSH_MOBILE_ADMIN_CONTRACT_FIXTURE="$FIXTURE_FILE" \
    go test ./internal/relay -run '^TestExportAdminAPIContractFixture$' -count=1
)

if [[ ! -s "$FIXTURE_FILE" ]]; then
  echo 'Go administrator contract fixture was not produced.' >&2
  exit 1
fi

(
  cd "$ROOT_DIR/front"
  SSH_MOBILE_ADMIN_CONTRACT_FIXTURE="$FIXTURE_FILE" \
    npm run test:run -- src/schemas/admin-contract.test.ts
)

echo 'Front ↔ Relay administrator API contract passed.'
