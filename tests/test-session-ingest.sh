#!/bin/bash
# Session ingest and a line that is still being written when it runs. The
# scripts stored the file size as the next offset, so the rest of such a line
# was read on its own next time and the event was lost. Now the line is read
# again, whole, once it is finished — and no event is ingested twice, however
# many reads the line spans. The stored offset stops where that line starts.
# When a writer never finished its line and the next line got glued onto it,
# that next line is still ingested, and so is the line before it when only
# its newline was lost.
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

# offset_of <offsets dir> <file>: the offset stored for that session file
offset_of() { cat "$1/$(printf '%s' "$2" | shasum -a 256 | cut -d' ' -f1).offset" 2>/dev/null; }
size_of() { wc -c < "$1" | tr -d ' '; }

# --- Codex -------------------------------------------------------------------
codex_line() {  # codex_line <minute> <total tokens>
  printf '{"timestamp":"2026-10-28T01:%02d:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":%d},"last_token_usage":{"total_tokens":1}}}}' "$1" "$2"
}
home="$scratch/codex"
mkdir -p "$home/.codex/sessions/2026/10/28"
file="$home/.codex/sessions/2026/10/28/rollout-test.jsonl"
offsets="$home/Library/Application Support/ClaudePace/.codex-offsets"
first="$(codex_line 0 10)"
second="$(codex_line 1 20)"
third="$(codex_line 2 30)"
ingest_codex() { HOME="$home" "$bin" ingest-codex-sessions >/dev/null 2>&1; }

# 1) the run lands while the second line is half written
{ printf '%s\n' "$first"; printf '%s' "${second:0:50}"; } > "$file"
ingest_codex
check "codex: the finished line is ingested" 1 "$(records "$home" codex-session)"
check "codex: the offset stops where the half-written line starts" $((${#first} + 1)) "$(offset_of "$offsets" "$file")"

# 2) once the line is finished it is picked up, exactly once
printf '%s\n' "${second:50}" >> "$file"
ingest_codex
check "codex: the half-written line is picked up later" 2 "$(records "$home" codex-session)"
check "codex: then the offset is the end of the file" "$(size_of "$file")" "$(offset_of "$offsets" "$file")"
ingest_codex
check "codex: nothing is ingested twice" 2 "$(records "$home" codex-session)"

# 3) a complete last line without a newline is taken at once, and the
#    newline that follows later brings nothing new
printf '%s' "$third" >> "$file"
ingest_codex
check "codex: a complete unterminated line is ingested" 3 "$(records "$home" codex-session)"
check "codex: and the offset moves past it" "$(size_of "$file")" "$(offset_of "$offsets" "$file")"
printf '\n' >> "$file"
ingest_codex
check "codex: its newline adds nothing" "3 $(size_of "$file")" "$(records "$home" codex-session) $(offset_of "$offsets" "$file")"

# --- Claude ------------------------------------------------------------------
claude_line() {  # claude_line <request id> <output tokens>
  printf '{"type":"assistant","requestId":"%s","timestamp":"2026-10-28T02:00:00Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":%d}}}' "$1" "$2"
}
home="$scratch/claude"
mkdir -p "$home/.claude/projects/-Users-me-project"
file="$home/.claude/projects/-Users-me-project/session.jsonl"
offsets="$home/Library/Application Support/ClaudePace/.claude-session-offsets"
one="$(claude_line req_1 5)"
two="$(claude_line req_2 7)"
ingest_claude() { HOME="$home" "$bin" ingest-claude-sessions >/dev/null 2>&1; }

{ printf '%s\n' "$one"; printf '%s' "${two:0:40}"; } > "$file"
ingest_claude
check "claude: the finished line is ingested" 1 "$(records "$home" claude-session)"
check "claude: the offset stops where the half-written line starts" $((${#one} + 1)) "$(offset_of "$offsets" "$file")"
printf '%s\n' "${two:40}" >> "$file"
ingest_claude
check "claude: the half-written line is picked up later" 2 "$(records "$home" claude-session)"
check "claude: then the offset is the end of the file" "$(size_of "$file")" "$(offset_of "$offsets" "$file")"
ingest_claude
check "claude: nothing is ingested twice" 2 "$(records "$home" claude-session)"

# --- A line glued onto a broken one ------------------------------------------
# A writer that dies mid-line never writes its newline, so the next line put in
# the same file (say by `claude --resume`) is glued onto the broken half. That
# complete line is read out of the glued one, once, and only if the source
# would take it as a line of its own. So is the line before it, when its writer
# died after its JSON, just before the newline.

# Brackets and braces inside strings, and an odd number of escaped quotes with
# brackets after the first: a scan that took every quote for a delimiter would
# leave the value thinking it is inside a string. Backslash runs come on both
# sides of a quote, and the second string ends in a backslash, so its closing
# quote has two before it. The first ends in "{", so `{"` turns up inside it.
tricky='["5\" } ] [ { \" \\ \\\" end\\ {","C:\\"]'

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
  local name="$1" event="$2" other="$3" marker="$4" key="$5" line waiting
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
  waiting="$(size_of "$file")"
  { printf '%s' "${line%%"$key"*}$key"; "$event" 104; } >> "$file"
  "$ingest"
  check "$name: a glued last line waits for its newline" "2 $waiting" "$(count) $(offset_of "$offsets" "$file")"
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

  # 7) the writer died after the JSON, just before the newline: that line is
  #    complete, and is ingested along with the line glued onto it (a run
  #    between the two would have taken it as a complete last line). Also when
  #    the glued line is one this source passes over, and in a CRLF file that
  #    lost only the \n. A complete line the source passes over stays passed
  #    over.
  {
    "$event" 113; "$event" 114; echo
    "$event" 115; "$other"; echo
    "$other"; "$event" 116; echo
    "$event" 117; printf '\r'; "$event" 118; printf '\r\n'
  } >> "$file"
  "$ingest"
  check "$name: a complete line that lost its newline is ingested with the glued one" "15 1 1 1 1 1 1" \
    "$(count) $(took 113) $(took 114) $(took 115) $(took 116) $(took 117) $(took 118)"

  # 8) but a complete object that ends a broken half is not a line: here an
  #    inner one, the half cut right after it
  { printf '%s' '{"type":"progress","data":{"message":'; "$event" 119; "$event" 120; echo; } >> "$file"
  "$ingest"
  check "$name: an object that ends a broken half is not taken" "16 0 1" "$(count) $(took 119) $(took 120)"
  rm -f "$offsets"/*.offset
  "$ingest"
  check "$name: reading the file again from the start adds nothing" 16 "$(count)"
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

# --- A long line read in pieces ----------------------------------------------
# A line of several MiB spans many reads. Written in two parts, it waits for
# its newline (the offset stops where it starts), then is ingested once along
# with the line after it. It is exactly 3 MiB, so the run that finishes it,
# reading from that offset, finds its newline as the first byte of a read
# (reads are 1 MiB). A long complete last line without a newline is taken at
# once.
long_line() {  # long_line <output tokens> <bytes>: an assistant turn that long
  local front back
  front="$(printf '{"type":"assistant","requestId":"req_long_%d","timestamp":"2026-10-28T05:00:00Z","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"' "$1")"
  back="$(printf '"}],"usage":{"input_tokens":1,"output_tokens":%d}}}' "$1")"
  printf '%s' "$front"
  head -c $(($2 - ${#front} - ${#back})) /dev/zero | tr '\0' x
  printf '%s' "$back"
}
home="$scratch/claude-long"
mkdir -p "$home/.claude/projects/-Users-me-project"
file="$home/.claude/projects/-Users-me-project/long.jsonl"
offsets="$home/Library/Application Support/ClaudePace/.claude-session-offsets"
long="$scratch/long-line"
marker='"output_tokens":%d,'
long_line 300 $((3 << 20)) > "$long"
cut=$(((2 << 20) + 777))
{ claude_line req_a 1; echo; head -c "$cut" "$long"; } > "$file"
ingest_claude
check "long line: it waits for its newline" "1 0 $(($(claude_line req_a 1 | wc -c) + 1))" \
  "$(records "$home" claude-session) $(took 300) $(offset_of "$offsets" "$file")"
{ tail -c +$((cut + 1)) "$long"; echo; claude_line req_b 2; echo; } >> "$file"
ingest_claude
check "long line: once finished it is ingested, once" "3 1 1 $(size_of "$file")" \
  "$(records "$home" claude-session) $(took 300) $(took 2) $(offset_of "$offsets" "$file")"
ingest_claude
check "long line: a later run adds nothing" 3 "$(records "$home" claude-session)"
long_line 301 $(((3 << 20) + 4321)) >> "$file"
ingest_claude
check "long line: a complete one without a newline is taken at once" "4 1 $(size_of "$file")" \
  "$(records "$home" claude-session) $(took 301) $(offset_of "$offsets" "$file")"
echo >> "$file"
ingest_claude
check "long line: its newline adds nothing" "4 $(size_of "$file")" \
  "$(records "$home" claude-session) $(offset_of "$offsets" "$file")"

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures session-ingest assertions failed" >&2
  exit 1
fi
echo "PASS: session ingest picks up lines finished between runs, long lines read in pieces and lines glued onto broken ones"
