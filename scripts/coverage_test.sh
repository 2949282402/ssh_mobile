#!/usr/bin/env bash

# Compatibility entry point for the periodic client coverage review.
# The four domain-specific coverage scripts are now independent; callers that
# used the former generic name still receive the client Network V2 gate.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/client_coverage.sh" "$@"
