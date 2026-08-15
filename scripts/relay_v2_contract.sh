#!/usr/bin/env bash
#
# relay_v2_contract.sh — cross-language relay v2 contract check.
#
# Entry point for the Rust/Go relay v2 codec tests and the protocol-v2-contract
# CI job. Verifies that the frozen golden fixtures in protocol/relay_v2_testdata/
# are current by deterministically regenerating them and diffing against what is
# committed, then runs the optional toolchain gates that are available:
#
#   1. regenerate golden fixtures  +  git diff --exit-code (REQUIRED)
#   2. protoc --descriptor_set_out=/dev/null  (if protoc available)
#   3. buf lint                      (if buf AND protocol/buf.yaml available)
#
# Exit code 0 = contract intact; non-zero = drift or gate failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTDATA="$REPO_ROOT/protocol/relay_v2_testdata"
PROTO="$REPO_ROOT/protocol/proto/relay/v2/relay_v2.proto"
GENERATOR="$TESTDATA/generate_fixtures.py"

cd "$REPO_ROOT"

echo "== relay v2 contract check =="

# --- 1. Golden fixtures must be current (deterministic regenerate + diff) ---
python3 "$GENERATOR" --regenerate
if ! git diff --exit-code -- protocol/relay_v2_testdata/ >/dev/null; then
  echo "error: protocol/relay_v2_testdata/ is not current." >&2
  echo "Run:  python3 protocol/relay_v2_testdata/generate_fixtures.py --regenerate" >&2
  echo "then commit the regenerated files." >&2
  exit 1
fi
echo "golden fixtures: current (22 fixtures)"

# --- Semantic sanity: manifest shape ---
python3 - <<'PY'
import json, sys
with open("protocol/relay_v2_testdata/manifest.json") as f:
    m = json.load(f)
assert m["schema_version"] == 2, "manifest schema_version != 2"
assert len(m["fixtures"]) == 22, "expected 22 fixtures, got %d" % len(m["fixtures"])
assert m["constants"]["RELAY_V2_VERSION"] == 2
print("manifest: OK (%d fixtures)" % len(m["fixtures"]))
PY

# --- 2. Compile-check the proto if protoc is available ---
if command -v protoc >/dev/null 2>&1; then
  protoc --proto_path=protocol --descriptor_set_out=/dev/null "$PROTO"
  echo "proto compile-check: OK"
else
  echo "protoc not available; skipping proto compile-check"
fi

# --- 3. buf lint if buf + buf.yaml are available ---
if command -v buf >/dev/null 2>&1 && [ -f protocol/buf.yaml ]; then
  (cd protocol && buf lint)
  echo "buf lint: OK"
else
  echo "buf not available; skipping buf lint"
fi

echo "== relay v2 contract check: PASS =="
