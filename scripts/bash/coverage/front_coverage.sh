#!/usr/bin/env bash

# Collect and enforce the React/Vite front-end coverage gate independently.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
FRONT_DIR="$ROOT_DIR/front"

cd "$FRONT_DIR"

if [[ ! -d node_modules || ! -d node_modules/@vitest/coverage-v8 ]]; then
  npm ci
fi

exec npm run test:coverage "$@"
