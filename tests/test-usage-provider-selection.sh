#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-usage-provider-test.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT

swiftc \
  "$repo_dir/Sources/ClaudePace/CodexUsageSnapshot.swift" \
  "$repo_dir/Sources/ClaudePace/ClaudeUsageSnapshot.swift" \
  "$repo_dir/Sources/ClaudePace/UsageProviderSelection.swift" \
  "$repo_dir/Tests/UsageProviderSelectionTestMain.swift" \
  -o "$scratch_dir/usage-provider-selection-tests"

"$scratch_dir/usage-provider-selection-tests"
