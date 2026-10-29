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

# --- 1) full output: minute-bearing 5h reset, whole-hour weekly reset, model bucket
cat > "$scratch/full.txt" <<'OUT'
You are currently using your subscription to power your Claude Code usage

Current session: 22% used · resets Jul 22 at 8:50pm (Asia/Seoul)
Current week (all models): 5% used · resets Jul 29 at 2pm (Asia/Seoul)
Current week (Opus): 8% used · resets Jul 29 at 2pm (Asia/Seoul)

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

# Resets must be in the future — a printed instant that already passed is rolled
# forward, never stored in the past where the app would show a dead window.
now_epoch="$(date +%s)"
for path in fiveHour.resets_at sevenDay.resets_at; do
  v="$(field "$appdir/snapshot.json" "$path")"
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "$v" "$now_epoch" \
    || { failures=$((failures+1)); echo "FAIL: $path rolled into the future ($v <= $now_epoch)" >&2; }
done

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
cat > "$scratch/weekonly.txt" <<'OUT'
Current week (all models): 41% used · resets Aug 27 at 2pm (Asia/Seoul)
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

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures claude-usage-poll assertions failed" >&2
  exit 1
fi
echo "PASS: claude usage poll assertions"
