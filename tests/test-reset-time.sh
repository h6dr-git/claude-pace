#!/bin/bash
# `/usage` reset times on their own (Sources/ClaudePace/Collectors/UsageResetTime.swift):
# the year the output leaves out (late December, New Year, leap days) and
# Python's strptime rules, against explicit "now" values instead of today.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/claudepace-reset-time-test.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT

swiftc \
  "$repo_dir/Sources/ClaudePace/Collectors/UsageResetTime.swift" \
  "$repo_dir/tests/ResetTimeTestMain.swift" \
  -o "$scratch_dir/reset-time-tests"

"$scratch_dir/reset-time-tests"
