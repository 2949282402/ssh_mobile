#!/usr/bin/env bash

# Shared CI runtime predicates. Sourced by full_test.sh; keep command checks
# side-effect free so configuration and job helpers can reuse them.

command_available() {
  command -v "$1" >/dev/null 2>&1
}
