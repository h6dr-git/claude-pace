#!/bin/bash
# Isolated regression for `ClaudePace poll-usage` (formerly tools/poll-usage.sh).
# A fake `claude` on PATH replays recorded `/usage` shapes into a throwaway
# HOME, so no account is queried and the real snapshot is never touched.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
bin="${CLAUDE_PACE_BIN:-$repo_dir/.build/release/ClaudePace}"
[ -x "$bin" ] || { echo "build first: swift build -c release (or set CLAUDE_PACE_BIN)" >&2; exit 1; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ai-usage-poll-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

fake_home="$scratch/home"
appdir="$fake_home/Library/Application Support/ClaudePace"
mkdir -p "$appdir" "$scratch/bin"

cat > "$scratch/bin/claude" <<'FAKE'
#!/bin/bash
# `auth status` answers from FAKE_AUTH (default: signed in); anything else
# replays the recorded /usage fixture. Records the argv of each call so a test
# can assert that a signed-out CLI is never asked for /usage. FAKE_AUTH_SLEEP /
# FAKE_USAGE_SLEEP make the matching call hang for that many seconds.
printf '%s\n' "$*" >> "${FAKE_CALL_LOG:-/dev/null}"
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  [ -n "${FAKE_AUTH_SLEEP:-}" ] && exec sleep "$FAKE_AUTH_SLEEP"
  printf '%s' "${FAKE_AUTH:-{\"loggedIn\": true, \"authMethod\": \"oauth\"\}}"
  exit 0
fi
[ -n "${FAKE_USAGE_SLEEP:-}" ] && exec sleep "$FAKE_USAGE_SLEEP"
[ -n "${FAKE_USAGE_FILE:-}" ] && [ -f "$FAKE_USAGE_FILE" ] && cat "$FAKE_USAGE_FILE"
exit 0
FAKE
chmod +x "$scratch/bin/claude"

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    failures=$((failures + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual" >&2
  fi
}

run_poll() {
  HOME="$fake_home" PATH="$scratch/bin:$PATH" FAKE_USAGE_FILE="${1:-}" \
    "$bin" poll-usage >/dev/null 2>&1 || true
}

field() { python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print('<missing>'); sys.exit(0)
cur=d
for k in sys.argv[2].split('.'):
    if isinstance(cur,dict) and k in cur: cur=cur[k]
    else: print('<none>'); sys.exit(0)
print('<none>' if cur is None else cur)
" "$1" "$2"; }

# json <path>: the snapshot value at a dotted path as JSON (null stays null),
# or <missing>.
json() { python3 -c "
import json,sys
cur=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    if not (isinstance(cur,dict) and k in cur): print('<missing>'); sys.exit(0)
    cur=cur[k]
print(json.dumps(cur, sort_keys=True))
" "$appdir/snapshot.json" "$1"; }

canonical() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$1"; }

# check_instant <name> <epoch> <path>: the snapshot holds exactly that instant.
check_instant() {
  local actual
  actual="$(field "$appdir/snapshot.json" "$3")"
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) == float(sys.argv[2]) else 1)' "$2" "$actual" 2>/dev/null \
    || check "$1" "$2" "$actual"
}

# edit_snapshot key=JSON...: set top-level keys of snapshot.json (an empty
# value drops the key), turning what a poll left into the next poll's past.
edit_snapshot() {
  python3 - "$appdir/snapshot.json" "$@" <<'PY'
import json, sys
path = sys.argv[1]
snapshot = json.load(open(path))
for assignment in sys.argv[2:]:
    key, _, value = assignment.partition("=")
    if value:
        snapshot[key] = json.loads(value)
    else:
        snapshot.pop(key, None)
json.dump(snapshot, open(path, "w"))
PY
}

# /usage prints a reset in the account's zone without a year, dropping ":00" on
# whole hours. reset_at <seconds from now> <minutes|hour> prints one for
# Asia/Seoul ("Nov 17 at 8:50pm" with the minutes set to :50, or "Nov 18 at
# 2pm" on the hour), a tab, and the epoch it stands for.
reset_at() {
  python3 - "$1" "$2" <<'PY'
import datetime, sys
from zoneinfo import ZoneInfo
offset, form = int(sys.argv[1]), sys.argv[2]
t = datetime.datetime.now(ZoneInfo("Asia/Seoul")) + datetime.timedelta(seconds=offset)
t = t.replace(minute=50 if form == "minutes" else 0, second=0, microsecond=0)
month = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()[t.month - 1]
clock = str(t.hour % 12 or 12) + (f":{t.minute:02d}" if form == "minutes" else "")
print(f"{month} {t.day} at {clock}{'am' if t.hour < 12 else 'pm'}\t{int(t.timestamp())}")
PY
}

# --- 1) full output: minute-bearing 5h reset, whole-hour weekly reset, model bucket
IFS=$'\t' read -r session_reset session_epoch < <(reset_at $((3 * 3600)) minutes)
IFS=$'\t' read -r week_reset week_epoch < <(reset_at $((2 * 86400)) hour)
cat > "$scratch/full.txt" <<OUT
You are currently using your subscription to power your Claude Code usage

Current session: 22% used · resets $session_reset (Asia/Seoul)
Current week (all models): 5% used · resets $week_reset (Asia/Seoul)
Current week (Opus): 8% used · resets $week_reset (Asia/Seoul)

What's contributing to your limits usage?
OUT
run_poll "$scratch/full.txt"
check "full: 5h percent"      "22" "$(field "$appdir/snapshot.json" fiveHour.used_percentage)"
check "full: week percent"    "5"  "$(field "$appdir/snapshot.json" sevenDay.used_percentage)"
check "full: model bucket"    "8"  "$(field "$appdir/snapshot.json" modelWindows.Opus.used_percentage)"
check "full: state"           "ok" "$(field "$appdir/claude-collector-state.json" status)"
[ "$(field "$appdir/snapshot.json" fiveHour.resets_at)" != "<none>" ] \
  || { failures=$((failures+1)); echo "FAIL: full: 5h reset parsed (minutes)" >&2; }
[ "$(field "$appdir/snapshot.json" sevenDay.resets_at)" != "<none>" ] \
  || { failures=$((failures+1)); echo "FAIL: full: weekly reset parsed (whole hour, no minutes)" >&2; }
[ "$(field "$appdir/snapshot.json" modelWindows.Opus.resets_at)" != "<none>" ] \
  || { failures=$((failures+1)); echo "FAIL: full: model bucket inherits weekly reset" >&2; }

# Resets are stored exactly as printed: one still ahead as that instant...
check_instant "full: 5h reset as printed"     "$session_epoch" fiveHour.resets_at
check_instant "full: weekly reset as printed" "$week_epoch"    sevenDay.resets_at
check_instant "full: model reset as printed"  "$week_epoch"    modelWindows.Opus.resets_at

# ...and one that already passed as well, in the past where the app reads an
# ended window. Rolled forward by whole windows it paired the ended window's
# percentage with an invented reset.
IFS=$'\t' read -r passed_reset passed_epoch < <(reset_at $((-2 * 3600)) minutes)
printf 'Current session: 64%% used · resets %s (Asia/Seoul)\n' "$passed_reset" > "$scratch/passed.txt"
run_poll "$scratch/passed.txt"
check "passed reset: 5h percent" "64" "$(field "$appdir/snapshot.json" fiveHour.used_percentage)"
check_instant "passed reset: stored as printed, not rolled" "$passed_epoch" fiveHour.resets_at
[ "$passed_epoch" -lt "$(date +%s)" ] \
  || { failures=$((failures+1)); echo "FAIL: passed reset: fixture $passed_epoch is not in the past" >&2; }

# --- 2) expired CLI login: snapshot frozen, cause named
before="$(cat "$appdir/snapshot.json")"
printf 'Failed to authenticate: OAuth session expired and could not be refreshed\n' > "$scratch/auth.txt"
run_poll "$scratch/auth.txt"
check "signed-out: snapshot untouched" "$before" "$(cat "$appdir/snapshot.json")"
check "signed-out: state" "signed-out" "$(field "$appdir/claude-collector-state.json" status)"

# --- 3) current output shape with no limit lines at all
cat > "$scratch/nolimits.txt" <<'OUT'
You are currently using your subscription to power your Claude Code usage

What's contributing to your limits usage?
Last 24h · 104 requests · 3 sessions
OUT
run_poll "$scratch/nolimits.txt"
check "no-limits: snapshot untouched" "$before" "$(cat "$appdir/snapshot.json")"
check "no-limits: state" "no-limits" "$(field "$appdir/claude-collector-state.json" status)"

# --- 4) empty output
: > "$scratch/empty.txt"
run_poll "$scratch/empty.txt"
check "empty: snapshot untouched" "$before" "$(cat "$appdir/snapshot.json")"
check "empty: state" "empty-output" "$(field "$appdir/claude-collector-state.json" status)"

# --- 5) weekly-only output still yields a usable window
IFS=$'\t' read -r later_week_reset _ < <(reset_at $((5 * 86400)) hour)
cat > "$scratch/weekonly.txt" <<OUT
Current week (all models): 41% used · resets $later_week_reset (Asia/Seoul)
OUT
run_poll "$scratch/weekonly.txt"
check "week-only: week percent" "41" "$(field "$appdir/snapshot.json" sevenDay.used_percentage)"
check "week-only: state" "ok" "$(field "$appdir/claude-collector-state.json" status)"

# --- 6) claude missing entirely
HOME="$fake_home" CLAUDE_BIN="$scratch/no-such-claude" \
  "$bin" poll-usage >/dev/null 2>&1 || true
check "cli-missing: state" "cli-missing" "$(field "$appdir/claude-collector-state.json" status)"

# --- 7) CLI reports signed out: named exactly, and /usage is never called
call_log="$scratch/calls.txt"
: > "$call_log"
HOME="$fake_home" PATH="$scratch/bin:$PATH" FAKE_CALL_LOG="$call_log" \
  FAKE_AUTH='{"loggedIn": false, "authMethod": "none"}' \
  FAKE_USAGE_FILE="$scratch/full.txt" \
  "$bin" poll-usage >/dev/null 2>&1 || true
check "signed-out precheck: state" "signed-out" "$(field "$appdir/claude-collector-state.json" status)"
if grep -q -- '-p /usage' "$call_log"; then
  failures=$((failures + 1))
  echo "FAIL: signed-out precheck: /usage was still called" >&2
fi

# --- 8) a signed-in CLI still reaches /usage
: > "$call_log"
HOME="$fake_home" PATH="$scratch/bin:$PATH" FAKE_CALL_LOG="$call_log" \
  FAKE_USAGE_FILE="$scratch/full.txt" \
  "$bin" poll-usage >/dev/null 2>&1 || true
check "signed-in: state" "ok" "$(field "$appdir/claude-collector-state.json" status)"
grep -q -- '-p /usage' "$call_log" || {
  failures=$((failures + 1))
  echo "FAIL: signed-in: /usage was not called" >&2
}
# Without --no-session-persistence this 180s poll leaves a throwaway session
# file behind on every run; two days of polling once buried the real session
# list under 314 stubs.
grep -q -- '--no-session-persistence' "$call_log" || {
  failures=$((failures + 1))
  echo "FAIL: signed-in: poll would leave a session file behind" >&2
}

# --- 9) a `/usage` call that never returns is stopped at the time limit: the
# snapshot is kept and the cause named, instead of every later poll stalling
before="$(cat "$appdir/snapshot.json")"
started=$SECONDS
HOME="$fake_home" PATH="$scratch/bin:$PATH" CLAUDE_USAGE_TIMEOUT=2 FAKE_USAGE_SLEEP=60 \
  FAKE_USAGE_FILE="$scratch/full.txt" \
  "$bin" poll-usage >/dev/null 2>&1 || true
elapsed=$((SECONDS - started))
check "usage timeout: snapshot untouched" "$before" "$(cat "$appdir/snapshot.json")"
check "usage timeout: state" "timed-out" "$(field "$appdir/claude-collector-state.json" status)"
[ "$elapsed" -lt 20 ] || { failures=$((failures + 1)); echo "FAIL: usage timeout: poll took ${elapsed}s" >&2; }

# --- 10) the same for `auth status`, and /usage is then not attempted
: > "$call_log"
started=$SECONDS
HOME="$fake_home" PATH="$scratch/bin:$PATH" CLAUDE_USAGE_TIMEOUT=2 FAKE_AUTH_SLEEP=60 \
  FAKE_CALL_LOG="$call_log" FAKE_USAGE_FILE="$scratch/full.txt" \
  "$bin" poll-usage >/dev/null 2>&1 || true
elapsed=$((SECONDS - started))
check "auth timeout: snapshot untouched" "$before" "$(cat "$appdir/snapshot.json")"
check "auth timeout: state" "timed-out" "$(field "$appdir/claude-collector-state.json" status)"
[ "$elapsed" -lt 20 ] || { failures=$((failures + 1)); echo "FAIL: auth timeout: poll took ${elapsed}s" >&2; }
if grep -q -- '-p /usage' "$call_log"; then
  failures=$((failures + 1))
  echo "FAIL: auth timeout: /usage was still called" >&2
fi

# --- 11) a normal poll afterwards recovers
HOME="$fake_home" PATH="$scratch/bin:$PATH" CLAUDE_USAGE_TIMEOUT=2 \
  FAKE_USAGE_FILE="$scratch/full.txt" \
  "$bin" poll-usage >/dev/null 2>&1 || true
check "after timeout: state" "ok" "$(field "$appdir/claude-collector-state.json" status)"

# --- 12) a statusLine render without rate_limits (Claude Code 2.1.x) leaves
# the /usage snapshot alone instead of blanking it until the next poll
before="$(cat "$appdir/snapshot.json")"
text="$(printf '%s' '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"session_id":"x"}' \
  | HOME="$fake_home" "$bin" statusline 2>/dev/null)"
check "statusline without limits: snapshot untouched" "$before" "$(cat "$appdir/snapshot.json")"
check "statusline without limits: status text" "⏱ AI Usage · Claude (rate_limits 대기…)" "$text"
[ ! -e "$appdir/snapshot.json.tmp" ] \
  || { failures=$((failures + 1)); echo "FAIL: statusline without limits: left snapshot.json.tmp behind" >&2; }

# --- 13) with rate_limits the statusLine still replaces the snapshot
printf '%s' '{"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1893456000},"seven_day":{"used_percentage":12,"resets_at":1893456000}}}' \
  | HOME="$fake_home" "$bin" statusline >/dev/null 2>&1
check "statusline with limits: 5h percent" "30" "$(field "$appdir/snapshot.json" fiveHour.used_percentage)"
check "statusline with limits: week percent" "12" "$(field "$appdir/snapshot.json" sevenDay.used_percentage)"

# --- 14) a percentage without a readable reset keeps a reset still ahead...
printf '%s\n' 'Current session: 3% used' > "$scratch/noreset.txt"
run_poll "$scratch/noreset.txt"
check "no reset, future prior: 5h percent" "3" "$(field "$appdir/snapshot.json" fiveHour.used_percentage)"
check "no reset, future prior: reset kept" "1893456000" "$(field "$appdir/snapshot.json" fiveHour.resets_at)"

# --- 15) ...but never inherits one that has already passed (it belongs to an
# ended window, and the menu would read the new number as "no window open")
python3 - "$appdir/snapshot.json" <<'PY'
import json, sys
path = sys.argv[1]
snapshot = json.load(open(path))
snapshot["fiveHour"]["resets_at"] = 1000000000
json.dump(snapshot, open(path, "w"))
PY
run_poll "$scratch/noreset.txt"
check "no reset, past prior: 5h percent" "3" "$(field "$appdir/snapshot.json" fiveHour.used_percentage)"
check "no reset, past prior: stale reset dropped" "<none>" "$(field "$appdir/snapshot.json" fiveHour.resets_at)"
check "no reset, past prior: state" "ok" "$(field "$appdir/claude-collector-state.json" status)"

# --- 16) an account with no 5-hour limit (verified Ultra accounts lost it from
# 2026-10-30) gets no session line, exactly as between two 5-hour windows.
# Weekly usage that grew between two polls under 5 hours apart, with no 5-hour
# window open at the first, settles it: with the limit, that usage would have
# opened a window still open at the second poll, which then prints the line.
IFS=$'\t' read -r weekly_reset _ < <(reset_at $((26 * 3600)) hour)
weekly_output() {  # weekly_output <file> <all models %> <Fable %>: the 2026-11-17 shape
  printf '%s\n' 'You are currently using your subscription to power your Claude Code usage' '' \
    "Current week (all models): $2% used · resets $weekly_reset (Asia/Seoul)" \
    "Current week (Fable): $3% used · resets $weekly_reset (Asia/Seoul)" > "$1"
}
weekly_output "$scratch/week60.txt" 60 91
weekly_output "$scratch/week61.txt" 61 91
weekly_output "$scratch/fable92.txt" 60 92

# previous_poll <seconds ago> <fiveHour JSON>: what the poll before the next one
# left: weekly only, 60% and Fable 91%, that long ago, with this 5h window.
previous_poll() {
  run_poll "$scratch/week60.txt"
  edit_snapshot "capturedAt=$(($(date +%s) - $1))" "fiveHour=$2" "fiveHourAbsentSince="
}
# The last window, ended days ago, like the one the 2026-11-17 snapshot kept.
ended="{\"used_percentage\": 9, \"resets_at\": $(($(date +%s) - 3 * 86400)).0}"

previous_poll 180 "$ended"
run_poll "$scratch/week61.txt"
check "no 5h limit: 5h window" "null" "$(json fiveHour)"
check "no 5h limit: since this poll" "$(json capturedAt)" "$(json fiveHourAbsentSince)"
check "no 5h limit: week percent" "61" "$(json sevenDay.used_percentage)"
check "no 5h limit: state" "ok" "$(field "$appdir/claude-collector-state.json" status)"
absent_since="$(json fiveHourAbsentSince)"

# --- 17) ...and it holds on later weekly-only polls with no new evidence (no
# growth, 6 hours on)
edit_snapshot "capturedAt=$(($(date +%s) - 6 * 3600))"
run_poll "$scratch/week61.txt"
check "no 5h limit kept: 5h window" "null" "$(json fiveHour)"
check "no 5h limit kept: since unchanged" "$absent_since" "$(json fiveHourAbsentSince)"

# --- 18) ...until a session line is back: read as usual, the absence dropped
run_poll "$scratch/full.txt"
check "session line back: 5h percent" "22" "$(json fiveHour.used_percentage)"
check_instant "session line back: 5h reset" "$session_epoch" fiveHour.resets_at
check "session line back: absence dropped" "<missing>" "$(json fiveHourAbsentSince)"

# --- 19) no growth: maybe just between two 5-hour windows, so the ended window
# stays for the app to say so
previous_poll 180 "$ended"
run_poll "$scratch/week60.txt"
check "no growth: ended window kept" "$(canonical "$ended")" "$(json fiveHour)"
check "no growth: not concluded" "<missing>" "$(json fiveHourAbsentSince)"

# --- 20) growth over more than 5 hours: a window could have opened and ended
# in between
previous_poll $((6 * 3600)) "$ended"
run_poll "$scratch/week61.txt"
check "growth over 6h: ended window kept" "$(canonical "$ended")" "$(json fiveHour)"
check "growth over 6h: not concluded" "<missing>" "$(json fiveHourAbsentSince)"

# --- 21) growth, but a 5-hour window was still open at the previous poll: the
# usage may have gone into it before it ended a minute ago
closed="{\"used_percentage\": 40, \"resets_at\": $(($(date +%s) - 60)).0}"
previous_poll 180 "$closed"
run_poll "$scratch/week61.txt"
check "window open before: kept" "$(canonical "$closed")" "$(json fiveHour)"
check "window open before: not concluded" "<missing>" "$(json fiveHourAbsentSince)"

# --- 22) the same for a 5-hour percentage whose reset could not be read
previous_poll 180 '{"used_percentage": 40, "resets_at": null}'
run_poll "$scratch/week61.txt"
check "unknown reset before: kept" '{"resets_at": null, "used_percentage": 40}' "$(json fiveHour)"
check "unknown reset before: not concluded" "<missing>" "$(json fiveHourAbsentSince)"

# --- 23) growth against another weekly reset compares two different windows
IFS=$'\t' read -r next_week_reset _ < <(reset_at $((8 * 86400)) hour)
printf '%s\n' "Current week (all models): 70% used · resets $next_week_reset (Asia/Seoul)" > "$scratch/next-week.txt"
previous_poll 180 "$ended"
run_poll "$scratch/next-week.txt"
check "another weekly window: ended window kept" "$(canonical "$ended")" "$(json fiveHour)"
check "another weekly window: not concluded" "<missing>" "$(json fiveHourAbsentSince)"

# --- 24) growth in a per-model weekly bucket counts too, and the poll says so
previous_poll 180 "$ended"
output="$(HOME="$fake_home" PATH="$scratch/bin:$PATH" FAKE_USAGE_FILE="$scratch/fable92.txt" \
  "$bin" poll-usage 2>/dev/null || true)"
check "model growth: 5h window" "null" "$(json fiveHour)"
check "model growth: since this poll" "$(json capturedAt)" "$(json fiveHourAbsentSince)"
check "model growth: output" \
  "snapshot updated: 5h=None% week=60% models=['Fable'] capturedAt=$(json capturedAt) fiveHourAbsentSince=$(json capturedAt)" \
  "$output"

# --- 25) a session line that cannot be read still means a 5-hour limit
printf '%s\n' 'Current session: ?% used' \
  "Current week (all models): 62% used · resets $weekly_reset (Asia/Seoul)" > "$scratch/session-unread.txt"
previous_poll 180 null
edit_snapshot "fiveHourAbsentSince=$(($(date +%s) - 3600))"
run_poll "$scratch/session-unread.txt"
check "unreadable session line: absence dropped" "<missing>" "$(json fiveHourAbsentSince)"
check "unreadable session line: no 5h reading" "{}" "$(json fiveHour)"
check "unreadable session line: week percent" "62" "$(json sevenDay.used_percentage)"
check "unreadable session line: state" "ok" "$(field "$appdir/claude-collector-state.json" status)"

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures claude-usage-poll assertions failed" >&2
  exit 1
fi
echo "PASS: claude usage poll assertions"
