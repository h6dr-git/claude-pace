#!/bin/bash
# Session ingest and a line that is still being written when it runs. The
# scripts stored the file size as the next offset, so the rest of such a line
# was read on its own next time and the event was lost. Now the line is read
# again, whole, once it is finished — and no event is ingested twice. When a
# writer never finished its line and the next line got glued onto it, that
# next line is still ingested.
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

# --- A line glued onto a broken one ------------------------------------------
# A writer that dies mid-line never writes its newline, so the next line put in
# the same file (say by `claude --resume`) is glued onto the broken half. That
# complete line is read out of the glued one, once, and only if the source
# would take it as a line of its own.

# A JSON string with brackets and braces, escaped quotes and backslash runs on
# both sides of a quote; it ends in "{", so `{"` turns up inside it too.
tricky='"} ] [ { \" \\ \\\" end\\ {"'

codex_event() {  # codex_event <n>: a token_count line with n total tokens
  printf '{"timestamp":"2026-10-28T03:%02d:00Z","type":"event_msg","payload":{"type":"token_count","note":%s,"info":{"total_token_usage":{"total_tokens":%d},"last_token_usage":{"total_tokens":1}}}}' "$(($1 % 60))" "$tricky" "$1"
}
codex_other() {  # a complete line the Codex source passes over
  printf '%s' '{"timestamp":"2026-10-28T04:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"hi"}}'
}
claude_event() {  # claude_event <n>: an assistant turn with n output tokens
  printf '{"type":"assistant","requestId":"req_%d","timestamp":"2026-10-28T03:00:00Z","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":%s}],"usage":{"input_tokens":1,"output_tokens":%d}}}' "$1" "$tricky" "$1"
}
claude_other() {  # a complete line the Claude source passes over
  printf '%s' '{"type":"user","timestamp":"2026-10-28T04:00:00Z","message":{"role":"user","content":"hi"}}'
}

# took <n>: ledger records of event n in $home ($marker, a printf format, finds them)
took() { grep -cF -- "$(printf "$marker" "$1")" "$home/Library/Application Support/ClaudePace/usage-log.jsonl"; }

# glued_checks <name> <event fn> <other fn> <marker> <key>: runs on $file and
# $plain_file with $ingest. A half that ends right after <key> reads the glued
# line as that key's value.
glued_checks() {
  local name="$1" event="$2" other="$3" marker="$4" key="$5" line
  count() { records "$home" "$source"; }

  # 1) a run lands on a half-written line, then another writer's line is
  #    glued onto it
  line="$("$event" 101)"
  { "$event" 100; echo; printf '%s' "${line:0:60}"; } > "$file"
  "$ingest"
  check "$name: the line before the broken one is ingested" 1 "$(count)"
  { "$event" 102; echo; } >> "$file"
  "$ingest"
  check "$name: the line glued onto a half line is ingested, once" "2 1 0" "$(count) $(took 102) $(took 101)"
  "$ingest"
  check "$name: a later run does not ingest it again" 2 "$(count)"
  rm -f "$offsets"/*.offset
  "$ingest"
  check "$name: nor does reading the file again from the start" 2 "$(count)"

  # 2) the glued line has no newline yet: it waits for one, like any last
  #    line that is not JSON on its own
  line="$("$event" 103)"
  { printf '%s' "${line%%"$key"*}$key"; "$event" 104; } >> "$file"
  "$ingest"
  check "$name: a glued last line waits for its newline" 2 "$(count)"
  echo >> "$file"
  "$ingest"
  check "$name: and is ingested once it has one" "3 1 0" "$(count) $(took 104) $(took 103)"

  # 3) the half ends inside a string, right after a backslash
  line="$("$event" 105)"
  { printf '%s' "${line%%\\*}\\"; "$event" 106; echo; } >> "$file"
  "$ingest"
  check "$name: a line glued after a cut escape is ingested" "4 1 0" "$(count) $(took 106) $(took 105)"

  # 4) nothing complete to take, or nothing this source takes: skipped, and
  #    the line after them still counts
  line="$("$event" 107)"
  {
    printf '%s' "${line%%"$key"*}$key"; "$other"; echo
    printf '%s%s\n' "${line:0:70}" "${line:0:90}"
    printf '%s%s\n' "${line:0:70}" '{"type":"token_count","type":"assistant",oops}'
    printf '%s\n' 'not json "type":"token_count" "type":"assistant" }'
    "$event" 108; echo
  } >> "$file"
  "$ingest"
  check "$name: broken lines with nothing to take are skipped" "5 1 0" "$(count) $(took 108) $(took 107)"

  # 5) an ordinary file is read as before, and the glued line's record is the
  #    one the same line gets on its own (but for its file and event id)
  { "$event" 102; echo; "$other"; echo; "$event" 109; echo; } > "$plain_file"
  "$ingest"
  check "$name: an ordinary file is unaffected" "7 1" "$(count) $(took 109)"
  check "$name: the glued line's record matches the plain one" "2 1" "$(took 102) $(
    grep -F -- "$(printf "$marker" 102)" "$home/Library/Application Support/ClaudePace/usage-log.jsonl" |
      sed -E 's/"event_id":"[^"]*"|"sourcePath":"[^"]*"//g' | sort -u | wc -l | tr -d ' ')"

  # 6) a file with CRLF line ends: every line, the glued one too, ends in \r
  line="$("$event" 111)"
  { "$event" 110; printf '\r\n%s' "${line:0:60}"; "$event" 112; printf '\r\n'; } >> "$file"
  "$ingest"
  check "$name: a CRLF line is ingested" 1 "$(took 110)"
  check "$name: a line glued onto a half line in a CRLF file is ingested, once" "9 1 0" "$(count) $(took 112) $(took 111)"
}

home="$scratch/codex-glued"
mkdir -p "$home/.codex/sessions/2026/10/28"
file="$home/.codex/sessions/2026/10/28/rollout-glued.jsonl"
plain_file="$home/.codex/sessions/2026/10/28/rollout-plain.jsonl"
offsets="$home/Library/Application Support/ClaudePace/.codex-offsets"
ingest=ingest_codex source=codex-session
glued_checks codex codex_event codex_other '"total":{"total_tokens":%d}' '"info":'

home="$scratch/claude-glued"
mkdir -p "$home/.claude/projects/-Users-me-project"
file="$home/.claude/projects/-Users-me-project/glued.jsonl"
plain_file="$home/.claude/projects/-Users-me-project/plain.jsonl"
offsets="$home/Library/Application Support/ClaudePace/.claude-session-offsets"
ingest=ingest_claude source=claude-session
glued_checks claude claude_event claude_other '"output_tokens":%d,' '"usage":'

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures session-ingest assertions failed" >&2
  exit 1
fi
echo "PASS: session ingest picks up lines finished between runs and lines glued onto broken ones"
