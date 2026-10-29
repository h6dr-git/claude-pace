#!/bin/bash

set -u

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
bin="${CLAUDE_PACE_BIN:-$repo_dir/.build/release/ClaudePace}"
[ -x "$bin" ] || { echo "build first: swift build -c release (or set CLAUDE_PACE_BIN)" >&2; exit 1; }
test_root="${1:-$(mktemp -d "${TMPDIR:-/tmp}/claudepace-rotation-test.XXXXXX")}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  expected="$1"
  actual="$2"
  label="$3"
  [ "$expected" = "$actual" ] || fail "$label expected=$expected actual=$actual"
}

fixture_home="$test_root/home"
fixture_app="$fixture_home/Library/Application Support/ClaudePace"
fixture_log="$fixture_app/usage-log.jsonl"
mkdir -p "$fixture_app"

printf '%s\n' \
  '{"schema":"usage.v1","source":"codex-session","event_id":"c1","timestamp":"2026-08-10T00:00:00Z","tokenUsage":{"total":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":100},"last":{"total_tokens":10}},"sourcePath":"session-a"}' \
  '{"schema":"usage.v1","source":"codex-session","event_id":"c2","timestamp":"2026-08-10T00:10:00Z","tokenUsage":{"total":{"input_tokens":70,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":160},"last":{"total_tokens":20}},"sourcePath":"session-a"}' \
  '{"schema":"usage.v1","source":"claude-statusline","event_id":"h1","timestamp":"2026-08-10T00:20:00Z","tokenUsage":null,"rateLimits":{},"sourcePath":"Claude Code statusLine"}' \
  > "$fixture_log"

before_hash=$(shasum -a 256 "$fixture_log" | awk '{print $1}')
before_bytes=$(wc -c < "$fixture_log" | tr -d ' ')
before_lines=$(wc -l < "$fixture_log" | tr -d ' ')
before_inode=$(stat -f '%i' "$fixture_log")

rotation_output=$(HOME="$fixture_home" USAGE_LOG_MAX_BYTES=1 USAGE_LOG_CURRENT_PERIOD=2026-08 \
  "$bin" usage-log-rotate "$fixture_log") || fail "threshold rotation"
archive_log="$fixture_app/archive/usage-log-2026-08-001.jsonl"
archive_summary="${archive_log%.jsonl}.summary.json"

[ -f "$archive_log" ] || fail "archive segment missing"
[ -f "$archive_summary" ] || fail "archive summary missing"
[ ! -s "$fixture_log" ] || fail "active log should be empty after rotation"
assert_eq "$before_hash" "$(shasum -a 256 "$archive_log" | awk '{print $1}')" "segment hash"
assert_eq "$before_bytes" "$(wc -c < "$archive_log" | tr -d ' ')" "segment bytes"
assert_eq "$before_lines" "$(wc -l < "$archive_log" | tr -d ' ')" "segment lines"
assert_eq "$before_inode" "$(stat -f '%i' "$archive_log")" "mv inode"
assert_eq "3" "$(jq -r '.records' "$archive_summary")" "segment records"
assert_eq "3" "$(jq -r '.lines' "$archive_summary")" "segment JSON lines"
[ "$(find "$fixture_app/archive" -type f -name '*.gz' | wc -l | tr -d ' ')" -eq 0 ] || fail "compressed archive created"

# App summary must work while the archived JSONL is unreadable: it may stat the
# inode, but it must consume the precomputed summary rather than open the data.
chmod 000 "$archive_log"
light_summary=$(HOME="$fixture_home" "$bin" usage-history-summary "$fixture_log") || fail "light summary"
chmod 600 "$archive_log"
assert_eq "3" "$(printf '%s\n' "$light_summary" | jq -r '.records')" "light archive records"
assert_eq "2" "$(printf '%s\n' "$light_summary" | jq -r '.bySource[] | select(.source == "codex-session") | .count')" "light Codex count"

printf '%s\n' \
  '{"schema":"usage.v1","source":"claude-session","event_id":"h2","timestamp":"2026-08-10T00:30:00Z","tokenUsage":{"input_tokens":1,"output_tokens":1},"rateLimits":null,"sourcePath":"session-h"}' \
  >> "$fixture_log"
light_summary=$(HOME="$fixture_home" "$bin" usage-history-summary "$fixture_log") || fail "combined light summary"
assert_eq "4" "$(printf '%s\n' "$light_summary" | jq -r '.records')" "combined records"

monthly=$(HOME="$fixture_home" "$bin" usage-monthly-summary "$fixture_log" 2026-08) || fail "monthly report"
daily=$(HOME="$fixture_home" "$bin" usage-daily-deltas "$fixture_log") || fail "daily report"
assert_eq "4" "$(printf '%s\n' "$monthly" | jq -r '.counts.totalEvents')" "monthly archived records"
assert_eq "60" "$(printf '%s\n' "$monthly" | jq -r '.codexObservedDelta.total_tokens')" "monthly archived delta"
assert_eq "2" "$(printf '%s\n' "$daily" | jq -r '.days[0].eventCount')" "daily archived events"
assert_eq "60" "$(printf '%s\n' "$daily" | jq -r '.days[0].observedDelta.total_tokens')" "daily archived delta"

# Month-boundary rotation uses the period marker and preserves the prior period
# in its segment name even when the size threshold is not reached.
month_home="$test_root/month-home"
month_app="$month_home/Library/Application Support/ClaudePace"
month_log="$month_app/usage-log.jsonl"
mkdir -p "$month_app"
printf '%s\n' '{"schema":"usage.v1","source":"claude-statusline","event_id":"m1","timestamp":"2026-07-31T14:59:00Z"}' > "$month_log"
printf '%s\n' '2026-07' > "$month_app/.usage-log-active-period"
HOME="$month_home" USAGE_LOG_MAX_BYTES=999999 USAGE_LOG_CURRENT_PERIOD=2026-08 \
  "$bin" usage-log-rotate "$month_log" >/dev/null || fail "month rotation"
[ -f "$month_app/archive/usage-log-2026-07-001.jsonl" ] || fail "month archive name"

# The 60-second Codex adapter performs automatic checks before and after its
# batch, while keeping every source event available for retry under the lock.
ingest_home="$test_root/ingest-home"
ingest_app="$ingest_home/Library/Application Support/ClaudePace"
sessions_dir="$ingest_home/sessions"
mkdir -p "$ingest_app" "$sessions_dir"
printf '%s\n' '{"schema":"usage.v1","source":"claude-statusline","event_id":"seed","timestamp":"2026-08-10T01:00:00Z"}' > "$ingest_app/usage-log.jsonl"
printf '%s\n' '{"timestamp":"2026-08-10T01:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":12},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":12},"model_context_window":1000},"rate_limits":null}}' > "$sessions_dir/session.jsonl"
HOME="$ingest_home" CODEX_SESSIONS_DIR="$sessions_dir" CODEX_USAGE_MTIME_DAYS=2 \
  USAGE_LOG_MAX_BYTES=1 USAGE_LOG_CURRENT_PERIOD=2026-08 \
  "$bin" ingest-codex-sessions >/dev/null || fail "automatic ingest rotation"
ingest_summary=$(HOME="$ingest_home" "$bin" usage-history-summary "$ingest_app/usage-log.jsonl") || fail "ingest aggregate"
assert_eq "2" "$(printf '%s\n' "$ingest_summary" | jq -r '.records')" "ingest preserved records"
assert_eq "2" "$(find "$ingest_app/archive" -type f -name 'usage-log-*.jsonl' | wc -l | tr -d ' ')" "pre/post ingest segments"

# Invalid JSON is retained in place and rotation is refused.
invalid_home="$test_root/invalid-home"
invalid_app="$invalid_home/Library/Application Support/ClaudePace"
invalid_log="$invalid_app/usage-log.jsonl"
mkdir -p "$invalid_app"
printf '%s\n' '{"source":"codex-session"}' 'not-json' > "$invalid_log"
invalid_hash=$(shasum -a 256 "$invalid_log" | awk '{print $1}')
if HOME="$invalid_home" USAGE_LOG_MAX_BYTES=1 USAGE_LOG_CURRENT_PERIOD=2026-08 \
  "$bin" usage-log-rotate "$invalid_log" >/dev/null 2>&1; then
  fail "invalid JSON rotation should fail"
fi
assert_eq "$invalid_hash" "$(shasum -a 256 "$invalid_log" | awk '{print $1}')" "invalid source retained"

echo "PASS: usage-log rotation, immutable summaries, archive-aware reports, and ingest integration"
echo "fixture_root=$test_root"
echo "$rotation_output"
