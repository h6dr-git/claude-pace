#!/bin/bash
# Poll the REAL account rate-limit % via the official `claude -p "/usage"` command
# and write it into ClaudePace's snapshot.json.
#
# WHY: statusLine only fires in a terminal TUI, so the menu bar goes stale the
# moment you work in the desktop app or the Obsidian Agent Client (ACP) — that
# usage never reaches snapshot.json. `/usage` is a built-in Claude Code command
# that reports the account-wide 5h/weekly window %, and it works headless
# (`claude -p "/usage"`) from ANY environment. Rate limits are account-global, so
# this value already includes desktop + terminal + claude.ai usage.
#
# SAFE: `/usage` is a read-only query — it does NOT consume the 5h/weekly quota
# (verified: two back-to-back calls returned identical %). Official command only,
# no private endpoints / OAuth token scraping / proxies (ToS-clean by design).
#
# Poll no more often than ~180s to stay clear of the usage endpoint's own
# request-rate cap. On any failure the existing snapshot is left untouched and
# the reason is recorded in claude-collector-state.json so the menu can say why
# instead of silently showing a frozen number.

set -u

appdir="$HOME/Library/Application Support/ClaudePace"
snap="$appdir/snapshot.json"
raw="$appdir/.usage-raw.txt"
state="$appdir/claude-collector-state.json"
mkdir -p "$appdir" 2>/dev/null

# Record why this poll ended the way it did. The app reads this file; a missing
# or unknown status is treated as "collection blocked", never as success.
write_state() {
  python3 - "$state" "$1" "${2:-}" <<'PYSTATE'
import json, os, sys, time
state_path, status, detail = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "schema": "claude-collector-state.v1",
    "status": status,
    "capturedAt": int(time.time()),
    "detail": detail,
}
tmp = state_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)
os.replace(tmp, state_path)
PYSTATE
}

# `claude` may not be on PATH under launchd — fall back to the known Homebrew
# path. CLAUDE_BIN overrides both, which is also how the isolated test keeps the
# real CLI out of the loop.
claude_bin="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo /opt/homebrew/bin/claude)}"
if [ ! -x "$claude_bin" ]; then
  write_state "cli-missing" "claude 실행 파일을 찾지 못했습니다"
  echo "claude cli not found" >&2
  exit 0
fi

# Ask the CLI whether it is signed in before spending a `/usage` round trip.
# A logged-out CLI does not print an auth error here — `/usage` just ends with
# the cost summary and no limit lines, which would otherwise be misdiagnosed as
# "the output format changed". `auth status` is a local, offline check.
auth_status="$("$claude_bin" auth status 2>/dev/null)"
if [ -n "$auth_status" ]; then
  logged_in="$(printf '%s' "$auth_status" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("loggedIn")
except Exception:
    print("unknown")
else:
    print("yes" if value is True else "no" if value is False else "unknown")
' 2>/dev/null)"
  if [ "$logged_in" = "no" ]; then
    write_state "signed-out" "터미널 claude가 로그아웃 상태입니다"
    echo "claude cli reports signed out, keeping snapshot" >&2
    exit 0
  fi
fi

# Run from an empty scratch dir. launchd hands the job no working directory, so
# Claude Code takes $HOME as the project root and walks it — that scan reaches
# TCC-protected app data (~/Library/Application Support/*) and macOS pops an
# "allow claude.exe?" prompt on every poll. An empty cwd has nothing to walk.
# The poll needs no MCP servers or browser bridge either.
scratch="$HOME/.claudepace/cwd"
mkdir -p "$scratch" 2>/dev/null
cd "$scratch" 2>/dev/null || cd / || exit 0

# --no-session-persistence keeps the 180s poll from leaving a throwaway session
# file behind on every run. Without it this poller alone wrote 314 stub sessions
# into ~/.claude/projects over two days and buried the real session list.
"$claude_bin" -p "/usage" \
  --no-session-persistence \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-chrome \
  </dev/null >"$raw" 2>&1

if [ ! -s "$raw" ]; then
  write_state "empty-output" '/usage 출력이 비어 있습니다'
  echo "usage output empty, keeping snapshot" >&2
  exit 0
fi

# An expired CLI login prints an auth error instead of the limit lines. Catch it
# here so the menu can name the fix rather than showing a stale percentage.
if grep -qiE "failed to authenticate|oauth session expired|invalid api key|please run /login|not logged in" "$raw"; then
  write_state "signed-out" "터미널 claude 로그인이 만료됐습니다"
  echo "claude cli signed out, keeping snapshot" >&2
  exit 0
fi

python3 - "$snap" "$raw" "$state" <<'PYEOF'
import json, sys, re, time, datetime, os

snap_path, raw_path, state_path = sys.argv[1], sys.argv[2], sys.argv[3]
out = open(raw_path, encoding='utf-8').read()

def write_state(status, detail=""):
    payload = {
        "schema": "claude-collector-state.v1",
        "status": status,
        "capturedAt": int(time.time()),
        "detail": detail,
    }
    tmp = state_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False)
    os.replace(tmp, state_path)

def tzinfo_for(name):
    if not name:
        return None
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:
        return None

def reset_epoch(text, tzname, length):
    """'Jul 22 at 8:50pm' / 'Jul 29 at 2pm' -> epoch, rolled into the future.

    `/usage` prints the reset instant without a year and drops ':00' on whole
    hours, so every accepted shape is tried before giving up."""
    if not text:
        return None
    text = text.strip()
    tz = tzinfo_for(tzname)
    now = datetime.datetime.now(tz) if tz else datetime.datetime.now()
    for fmt in ("%b %d at %I:%M%p", "%b %d at %I%p",
                "%b %d at %I:%M %p", "%b %d at %I %p"):
        try:
            dt = datetime.datetime.strptime(f"{text} {now.year}", fmt + " %Y")
        except ValueError:
            continue
        if tz:
            dt = dt.replace(tzinfo=tz)
        ep = dt.timestamp()
        # The printed instant may already have passed (or sit a year back across
        # a Dec/Jan boundary); walk it forward by whole windows.
        while ep < time.time():
            ep += length
        return ep
    return None

SESSION_RE = re.compile(
    r'^\s*Current session:\s*(\d+)%\s*used'
    r'(?:[^\S\n]*·[^\S\n]*resets\s+(.+?))?'
    r'(?:\s*\(([^)]*)\))?\s*$',
    re.M)
WEEK_RE = re.compile(
    r'^\s*Current week\s*\(([^)]*)\):\s*(\d+)%\s*used'
    r'(?:[^\S\n]*·[^\S\n]*resets\s+(.+?))?'
    r'(?:\s*\(([^)]*)\))?\s*$',
    re.M)

FIVE_HOURS = 5 * 3600
ONE_WEEK = 7 * 24 * 3600

five = None
five_reset = None
m = SESSION_RE.search(out)
if m:
    five = int(m.group(1))
    five_reset = reset_epoch(m.group(2), m.group(3), FIVE_HOURS)

week = None
week_reset = None
model_windows = {}
for m in WEEK_RE.finditer(out):
    name = (m.group(1) or '').strip()
    used = int(m.group(2))
    reset = reset_epoch(m.group(3), m.group(4), ONE_WEEK)
    if name.lower() in ('all models', 'all model', 'all'):
        week, week_reset = used, reset
    elif name:
        model_windows[name] = {'used_percentage': used, 'resets_at': reset}

# Bail if we couldn't read the core numbers — never overwrite with garbage, and
# say which of the two failure shapes this was.
if five is None and week is None:
    if re.search(r'Current (session|week)', out, re.I):
        write_state('parse-failed', '한도 줄은 있으나 형식을 해석하지 못했습니다')
        sys.stderr.write("limit lines present but unparsed, keeping snapshot\n")
    else:
        write_state('no-limits', '`/usage` 출력에 한도 줄이 없습니다')
        sys.stderr.write("no limit lines in output, keeping snapshot\n")
    sys.exit(0)

try:
    cur = json.load(open(snap_path))
    if not isinstance(cur, dict):
        cur = {}
except Exception:
    cur = {}

def window(old, used, reset):
    if used is None:
        return old
    w = dict(old) if isinstance(old, dict) else {}
    w['used_percentage'] = used
    if reset is not None:
        w['resets_at'] = reset          # prefer freshly parsed reset; else keep prior
    return w

new = dict(cur)
new['capturedAt'] = int(time.time())
new['fiveHour'] = window(cur.get('fiveHour') or {}, five, five_reset)
new['sevenDay'] = window(cur.get('sevenDay') or {}, week, week_reset)

# Per-model weekly buckets are keyed by the name `/usage` printed, so a renamed
# or new model shows up without a code change. Buckets missing a reset instant
# inherit the all-models weekly reset, which is the same window.
if model_windows:
    merged = dict(cur.get('modelWindows') or {})
    for name, w in model_windows.items():
        if w.get('resets_at') is None and week_reset is not None:
            w['resets_at'] = week_reset
        merged[name] = w
    new['modelWindows'] = merged

new['source'] = 'usage-poll'

tmp = snap_path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(new, f)
os.replace(tmp, snap_path)

write_state('ok', '')
print(f"snapshot updated: 5h={five}% week={week}% models={sorted(model_windows)} capturedAt={new['capturedAt']}")
PYEOF
