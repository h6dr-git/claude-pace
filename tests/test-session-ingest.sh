#!/bin/bash
# Session ingest and a line that is still being written when it runs. The
# scripts stored the file size as the next offset, so the rest of such a line
# was read on its own next time and the event was lost. Now the line is read
# again, whole, once it is finished — and no event is ingested twice.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
bin="${CLAUDE_PACE_BIN:-$repo_dir/.build/release/ClaudePace}"
[ -x "$bin" ] || { echo "build first: swift build -c release (or set CLAUDE_PACE_BIN)" >&2; exit 1; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/claudepace-ingest-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
unset CODEX_SESSIONS_DIR CLAUDE_PROJECTS_DIR CODEX_USAGE_MTIME_DAYS CLAUDE_USAGE_MTIME_DAYS \
  USAGE_LOG_MAX_BYTES USAGE_LOG_CURRENT_PERIOD USAGE_LOG_LOCK_TIMEOUT

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    failures=$((failures + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual" >&2
  fi
}

# records <home> <source>: ledger records from that source
records() {
  local log="$1/Library/Application Support/ClaudePace/usage-log.jsonl"
  if [ -f "$log" ]; then grep -c "\"source\":\"$2\"" "$log"; else echo 0; fi
}

# --- Codex -------------------------------------------------------------------
codex_line() {  # codex_line <minute> <total tokens>
  printf '{"timestamp":"2026-10-28T01:%02d:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":%d},"last_token_usage":{"total_tokens":1}}}}' "$1" "$2"
}
home="$scratch/codex"
mkdir -p "$home/.codex/sessions/2026/10/28"
file="$home/.codex/sessions/2026/10/28/rollout-test.jsonl"
first="$(codex_line 0 10)"
second="$(codex_line 1 20)"
third="$(codex_line 2 30)"
ingest_codex() { HOME="$home" "$bin" ingest-codex-sessions >/dev/null 2>&1; }

# 1) the run lands while the second line is half written
{ printf '%s\n' "$first"; printf '%s' "${second:0:50}"; } > "$file"
ingest_codex
check "codex: the finished line is ingested" 1 "$(records "$home" codex-session)"

# 2) once the line is finished it is picked up, exactly once
printf '%s\n' "${second:50}" >> "$file"
ingest_codex
check "codex: the half-written line is picked up later" 2 "$(records "$home" codex-session)"
ingest_codex
check "codex: nothing is ingested twice" 2 "$(records "$home" codex-session)"

# 3) a complete last line without a newline is taken at once, and the
#    newline that follows later brings nothing new
printf '%s' "$third" >> "$file"
ingest_codex
check "codex: a complete unterminated line is ingested" 3 "$(records "$home" codex-session)"
printf '\n' >> "$file"
ingest_codex
check "codex: its newline adds nothing" 3 "$(records "$home" codex-session)"

# --- Claude ------------------------------------------------------------------
claude_line() {  # claude_line <request id> <output tokens>
  printf '{"type":"assistant","requestId":"%s","timestamp":"2026-10-28T02:00:00Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":%d}}}' "$1" "$2"
}
home="$scratch/claude"
mkdir -p "$home/.claude/projects/-Users-me-project"
file="$home/.claude/projects/-Users-me-project/session.jsonl"
one="$(claude_line req_1 5)"
two="$(claude_line req_2 7)"
ingest_claude() { HOME="$home" "$bin" ingest-claude-sessions >/dev/null 2>&1; }

{ printf '%s\n' "$one"; printf '%s' "${two:0:40}"; } > "$file"
ingest_claude
check "claude: the finished line is ingested" 1 "$(records "$home" claude-session)"
printf '%s\n' "${two:40}" >> "$file"
ingest_claude
check "claude: the half-written line is picked up later" 2 "$(records "$home" claude-session)"
ingest_claude
check "claude: nothing is ingested twice" 2 "$(records "$home" claude-session)"

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures session-ingest assertions failed" >&2
  exit 1
fi
echo "PASS: session ingest picks up lines finished between runs"
