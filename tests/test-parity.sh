#!/bin/bash
# Parity check for the Swift port of the collectors. The original shell and
# Python scripts are taken from git history (LEGACY_REF) and run side by side
# with the `ClaudePace` subcommands on the same fixtures; then everything each
# run left behind is compared.
#
# Both runs use the same absolute HOME path, so session paths — which are
# hashed into offsets and event ids — are identical. Only values that depend on
# the wall clock are normalized (tests/parity/compare.py). Needs jq, python3
# and the git history that still contains the scripts.
set -u

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
bin="${CLAUDE_PACE_BIN:-$repo_dir/.build/release/ClaudePace}"
legacy_ref="${LEGACY_REF:-8a8441c97b58cf36ed308ea6edb205d77b290959}"
parity_dir="$repo_dir/tests/parity"

[ -x "$bin" ] || { echo "build first: swift build -c release (or set CLAUDE_PACE_BIN)" >&2; exit 1; }

# The app runs its collectors without locale variables, so the scripts' `sort`
# compared bytes. Keep that, and keep the caller's settings out of the runs.
export LC_ALL=C
# Interpreters must not drop caches into the fixture HOME.
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_BIN CODEX_BIN CODEX_SESSIONS_DIR CLAUDE_PROJECTS_DIR CODEX_USAGE_MTIME_DAYS \
  CLAUDE_USAGE_MTIME_DAYS USAGE_LOG_MAX_BYTES USAGE_LOG_CURRENT_PERIOD USAGE_LOG_LOCK_TIMEOUT \
  USAGE_DAY_OFFSET_SECONDS CLAUDEPACE_HISTORY_INTERVAL CLAUDE_USAGE_TIMEOUT

work="$(mktemp -d "${TMPDIR:-/tmp}/claudepace-parity.XXXXXX")"
trap 'rm -rf "$work"' EXIT

legacy="$work/legacy"
for file in \
  tools/poll-usage.sh tools/poll-codex-usage.py tools/ingest-codex-sessions.sh \
  tools/ingest-claude-sessions.sh tools/usage-log-rotate.sh tools/usage-log-segment-summary.sh \
  tools/usage-history-summary.sh tools/usage-daily-deltas.sh tools/usage-monthly-summary.sh \
  bridge/statusline.sh; do
  mkdir -p "$legacy/$(dirname "$file")"
  if ! git -C "$repo_dir" show "$legacy_ref:$file" > "$legacy/$file" 2>/dev/null; then
    echo "cannot read $file at $legacy_ref (a full clone is needed)" >&2
    exit 1
  fi
  chmod +x "$legacy/$file"
done

fakes="$work/bin"
mkdir -p "$fakes"
cp "$parity_dir/fake-claude" "$fakes/claude"
cp "$parity_dir/fake-codex" "$fakes/codex"
chmod +x "$fakes/claude" "$fakes/codex"

# --- running one collector -------------------------------------------------

# step <name> <command> [args...]: run the current implementation ($impl) with
# HOME=$home, keep its stdout and exit status under $home/_out.
step() {
  local name="$1"
  shift
  step_number=$((step_number + 1))
  local label
  label="$(printf '%02d-%s' "$step_number" "$name")"
  mkdir -p "$home/_out"
  local command="$1"
  shift
  if [ "$impl" = legacy ]; then
    case "$command" in
      poll-codex-usage) HOME="$home" python3 "$legacy/tools/poll-codex-usage.py" "$@" ;;
      statusline) HOME="$home" bash "$legacy/bridge/statusline.sh" "$@" ;;
      *) HOME="$home" bash "$legacy/tools/$command.sh" "$@" ;;
    esac >"$home/_out/$label.out" 2>"$home/_out/$label.err"
  else
    HOME="$home" "$bin" "$command" "$@" >"$home/_out/$label.out" 2>"$home/_out/$label.err"
  fi
  echo "$label exit=$?" >> "$home/_out/transcript"
}

# keep <label> <file>...: copy state files aside after a step.
keep() {
  local label="$1"
  shift
  mkdir -p "$home/_steps/$label"
  local file
  for file in "$@"; do
    [ -e "$file" ] && cp -p "$file" "$home/_steps/$label/"
  done
  return 0
}

failures=0
run_scenario() {
  local scenario="$1" impl
  for impl in legacy new; do
    home="$work/home"
    rm -rf "$home"
    mkdir -p "$home"
    step_number=0
    "$scenario"
    rm -rf "$work/result-$impl"
    mv "$home" "$work/result-$impl"
  done
  local steps ok
  steps=$(wc -l < "$work/result-new/_out/transcript" | tr -d ' ')
  ok=$(grep -c 'exit=0$' "$work/result-new/_out/transcript")
  if python3 "$parity_dir/compare.py" "$work/result-legacy" "$work/result-new" > "$work/compare.out"; then
    echo "PASS: $scenario ($(tail -n 1 "$work/compare.out"), $steps runs, $ok with exit 0)"
    echo "${scenario#scenario_}: $(tail -n 1 "$work/compare.out") from $steps runs ($ok exit 0)" >> "$work/digest.txt"
  else
    cat "$work/compare.out"
    echo "FAIL: $scenario" >&2
    annotate error "parity $scenario" "$work/compare.out"
    failures=$((failures + 1))
  fi
}

# annotate <level> <title> <file>: show a file's text as a CI annotation.
annotate() {
  [ -n "${GITHUB_ACTIONS:-}" ] || return 0
  python3 -c '
import sys
level, title, path = sys.argv[1:4]
body = open(path, encoding="utf-8", errors="replace").read()[:3500]
escape = lambda text: text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print("::" + level + " title=" + escape(title) + "::" + escape(body))
' "$1" "$2" "$3"
}

app_dir() { printf '%s' "$home/Library/Application Support/ClaudePace"; }

# --- Codex session ingestion -------------------------------------------------

scenario_ingest_codex() {
  local sessions="$home/.codex/sessions"
  local a="$sessions/2026/10/28/rollout-a.jsonl"
  local b="$sessions/2026/10/27/rollout-b.jsonl"
  mkdir -p "$sessions/2026/10/28" "$sessions/2026/10/27" "$sessions/2025/01/01" "$sessions/2030/01/01" "$sessions/.hidden"

  local normal='{"timestamp":"2026-10-28T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":12},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":12},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_in_seconds":1000},"secondary":null}}}'
  {
    printf '%s\n' "$normal" "$normal"
    printf '%s\n' '{"timestamp":"2026-10-28T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}'
    printf '%s\n' '{"timestamp":"2026-10-28T01:06:00.5Z","type":"event_msg","payload":{"type":"session_meta"}}'
    printf '%s\n' '{"timestamp":"2026-10-28T01:07:00Z","type":"token_count",'
    printf '%s\n' '{"timestamp":"2026-10-28T10:08:00+09:00","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":20},"last_token_usage":{"total_tokens":8}}}}'
    printf '%s\n' '{"timestamp":1793235000,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":30},"last_token_usage":{"total_tokens":10}}}}'
    printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":40}}}}'
    printf '%s\n' '{"timestamp":"2026-10-28T03:00:00Z","type":"token_count","payload":"oops"}'
    printf '%s\n' '{"timestamp":"2026-10-28T03:30:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":50},"last_token_usage":false,"model_context_window":false},"rate_limits":false}}'
    printf '%s\n' '{"timestamp":"2026-10-28T04:00:00.123456Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":60,"note":"한글 \"따옴표\" \\ /slash\u0001"},"last_token_usage":{"total_tokens":10}},"rate_limits":{"plan":"pro","x":1.50,"y":-0.0,"z":1e3,"big":12345678901234567890}}}'
    printf '%s\r\n' '{"timestamp":"2026-10-28T05:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":70},"last_token_usage":{"total_tokens":10}}}}'
  } > "$a"
  {
    printf '%s\n' '{"timestamp":"2026-10-27T09:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5},"last_token_usage":{"total_tokens":5}}}}'
    printf '%s' '{"timestamp":"2026-10-27T09:30:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9},"last_token_usage":{"total_tokens":4}}}}'
  } > "$b"
  printf '%s\n' '{"timestamp":"2026-10-28T07:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1}}}}' > "$sessions/2026/10/28/Rollout-Z.jsonl"
  printf '%s\n' '{"timestamp":"2026-10-28T07:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":2}}}}' > "$sessions/.hidden/rollout-h.jsonl"
  printf '%s\n' '{"timestamp":"2025-01-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":3}}}}' > "$sessions/2025/01/01/rollout-old.jsonl"
  touch -t 202601010000 "$sessions/2025/01/01/rollout-old.jsonl"
  printf '%s\n' '{"timestamp":"2030-01-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":4}}}}' > "$sessions/2030/01/01/rollout-future.jsonl"
  touch -t 203001010000 "$sessions/2030/01/01/rollout-future.jsonl"
  printf '%s\n' "$normal" > "$sessions/2026/10/28/rollout-c.json"
  ln -s "$a" "$sessions/link.jsonl"

  step ingest-1 ingest-codex-sessions
  printf '%s\n' '{"timestamp":"2026-10-28T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":90},"last_token_usage":{"total_tokens":20}}}}' >> "$a"
  step ingest-2 ingest-codex-sessions
  # Shrinking a file below its stored offset makes the next run read it from
  # the start again; events already seen stay deduplicated.
  printf '%s\n' '{"timestamp":"2026-10-27T09:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5},"last_token_usage":{"total_tokens":5}}}}' > "$b"
  step ingest-3 ingest-codex-sessions
  step ingest-4 ingest-codex-sessions
  CODEX_SESSIONS_DIR="$home/missing" step ingest-5 ingest-codex-sessions
}

# --- Claude session ingestion ------------------------------------------------

scenario_ingest_claude() {
  local projects="$home/.claude/projects"
  local s1="$projects/-Users-me-project/1a2b.jsonl"
  local agent="$projects/-Users-me-project/1a2b/subagents/agent-1.jsonl"
  mkdir -p "$(dirname "$s1")" "$(dirname "$agent")" "$projects/-Users-me-old"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-10-28T00:59:00Z"}'
    printf '%s\n' '{"type":"assistant","requestId":"req_1","timestamp":"2026-10-28T01:00:00.123Z","entrypoint":"cli","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":100,"cache_read_input_tokens":200}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_1","timestamp":"2026-10-28T01:00:01Z","entrypoint":"cli","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":9}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-10-28T01:01:00Z","message":{"id":"msg_2","model":"claude-sonnet-5-5","usage":{"input_tokens":1,"output_tokens":2}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-10-28T01:02:00Z","message":{"usage":{"output_tokens":3}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_null","timestamp":"2026-10-28T01:03:00Z","message":{"usage":null}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_no_output","timestamp":"2026-10-28T01:04:00Z","message":{"usage":{"input_tokens":9}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_false","timestamp":"2026-10-28T01:05:00Z","entrypoint":"sdk-ts","message":{"usage":{"output_tokens":false,"input_tokens":false}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_no_ts","message":{"usage":{"output_tokens":1}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_bad",'
    printf '%s\n' '{"type":"assistant","requestId":"req_text","timestamp":"2026-10-28T01:06:00Z","message":"text"}'
    printf '%s\n' '{"type":"assistant","requestId":12345,"timestamp":1793235000,"message":{"usage":{"output_tokens":4}}}'
    printf '%s\n' '{"type":"assistant","requestId":"","timestamp":"2026-10-28T01:07:00Z","message":{"id":"msg_empty","usage":{"output_tokens":1}}}'
  } > "$s1"
  printf '%s\n' '{"type":"assistant","requestId":"req_agent","timestamp":"2026-10-28T02:00:00Z","entrypoint":"sdk-ts","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":5}}}' > "$agent"
  printf '%s\n' '{"type":"assistant","requestId":"req_old","timestamp":"2025-12-01T00:00:00Z","message":{"usage":{"output_tokens":1}}}' > "$projects/-Users-me-old/old.jsonl"
  touch -t 202601010000 "$projects/-Users-me-old/old.jsonl"

  step ingest-1 ingest-claude-sessions
  printf '%s\n' '{"type":"assistant","requestId":"req_2","timestamp":"2026-10-28T03:00:00Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":2}}}' >> "$s1"
  step ingest-2 ingest-claude-sessions
  step ingest-3 ingest-claude-sessions
}

# --- ledger rotation, summaries and reports ----------------------------------

scenario_ledger() {
  local app log
  app="$(app_dir)"
  log="$app/usage-log.jsonl"
  mkdir -p "$app"
  printf '%s\n' \
    '{"schema":"usage.v1","source":"codex-session","event_id":"c1","timestamp":"2026-08-10T00:00:00Z","tokenUsage":{"total":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":100},"last":{"total_tokens":10}},"sourcePath":"session-a"}' \
    '{"schema":"usage.v1","source":"codex-session","event_id":"c2","timestamp":"2026-08-10T00:10:00Z","tokenUsage":{"total":{"input_tokens":70,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":160},"last":{"total_tokens":20}},"sourcePath":"session-a"}' \
    '{"schema":"usage.v1","source":"codex-session","event_id":"c3","timestamp":"2026-08-11T15:30:00.250Z","tokenUsage":{"total":{"input_tokens":5,"total_tokens":9},"last":{"total_tokens":9}},"sourcePath":"session-b"}' \
    '{"schema":"usage.v1","source":"claude-statusline","event_id":"h1","timestamp":"2026-08-10T00:20:00Z","tokenUsage":null,"rateLimits":{"five_hour":{"used_percentage":5}},"sourcePath":"Claude Code statusLine"}' \
    '{"schema":"usage.v1","source":"claude-statusline","event_id":"h0","timestamp":"2026-08-09T23:00:00Z","tokenUsage":null,"rateLimits":{},"sourcePath":"Claude Code statusLine"}' \
    '{"schema":"usage.v1","source":"claude-session","event_id":"s1","timestamp":"2026-07-31T15:30:00Z","tokenUsage":{"input_tokens":1,"output_tokens":1},"sourcePath":"session-h"}' \
    '{"schema":"usage.v1","event_id":"nosource","timestamp":"2026-08-12T00:00:00Z"}' \
    '{"schema":"usage.v1","source":42,"event_id":"numsource"}' \
    '{"schema":"usage.v1","source":"codex-session","event_id":"c4","timestamp":"2026-08-12T01:00:00+09:00","tokenUsage":{"total":{"total_tokens":200}},"sourcePath":"session-c"}' \
    > "$log"

  step history-1 usage-history-summary "$log"
  step daily-1 usage-daily-deltas "$log"
  step monthly-1 usage-monthly-summary "$log" 2026-08
  step monthly-2 usage-monthly-summary "$log" 2026-07
  USAGE_DAY_OFFSET_SECONDS=-3600 step daily-2 usage-daily-deltas "$log"
  USAGE_LOG_MAX_BYTES=999999999 USAGE_LOG_CURRENT_PERIOD=2026-08 step rotate-1 usage-log-rotate "$log"
  USAGE_LOG_MAX_BYTES=1 USAGE_LOG_CURRENT_PERIOD=2026-08 step rotate-2 usage-log-rotate "$log"
  printf '%s\n' '{"schema":"usage.v1","source":"codex-session","event_id":"c5","timestamp":"2026-08-13T00:00:00Z","tokenUsage":{"total":{"total_tokens":300},"last":{"total_tokens":100}},"sourcePath":"session-a"}' >> "$log"
  USAGE_LOG_MAX_BYTES=1 USAGE_LOG_CURRENT_PERIOD=2026-08 step rotate-3 usage-log-rotate "$log"
  rm -f "$app/archive/usage-log-2026-08-001.summary.json"
  USAGE_LOG_MAX_BYTES=999999999 USAGE_LOG_CURRENT_PERIOD=2026-08 step rotate-4 usage-log-rotate "$log"
  printf '%s\n' '{"schema":"usage.v1","source":"claude-statusline","event_id":"m1","timestamp":"2026-08-31T14:59:00Z","rateLimits":{}}' >> "$log"
  printf '%s\n' '2026-08' > "$app/.usage-log-active-period"
  USAGE_LOG_MAX_BYTES=999999999 USAGE_LOG_CURRENT_PERIOD=2026-09 step rotate-5 usage-log-rotate "$log"
  step history-2 usage-history-summary "$log"
  step daily-3 usage-daily-deltas "$log"
  step monthly-3 usage-monthly-summary "$log" 2026-08
  step segment-1 usage-log-segment-summary "$app/archive/usage-log-2026-08-002.jsonl" label-x
  step segment-2 usage-log-segment-summary "$app/archive/usage-log-2026-08-002.jsonl"
  step segment-3 usage-log-segment-summary "$app/archive/missing.jsonl"

  # Ledgers that must not rotate (and summaries that must fail).
  printf '%s\n' '{"source":"codex-session"}' 'not-json' > "$log"
  USAGE_LOG_MAX_BYTES=1 USAGE_LOG_CURRENT_PERIOD=2026-09 step rotate-6 usage-log-rotate "$log"
  step history-3 usage-history-summary "$log"
  printf '%s' '{"source":"x"}' > "$log"
  USAGE_LOG_MAX_BYTES=1 USAGE_LOG_CURRENT_PERIOD=2026-09 step rotate-7 usage-log-rotate "$log"
  printf '%s\n' '[1,2]' > "$log"
  USAGE_LOG_MAX_BYTES=1 USAGE_LOG_CURRENT_PERIOD=2026-09 step rotate-8 usage-log-rotate "$log"
  printf '%s\n' '{"source":"codex-session","timestamp":"2026-09-01T00:00:00Z","tokenUsage":7}' > "$log"
  step history-4 usage-history-summary "$log"
  step daily-4 usage-daily-deltas "$log"
  : > "$log"
  USAGE_LOG_MAX_BYTES=abc step rotate-9 usage-log-rotate "$log"
  USAGE_LOG_CURRENT_PERIOD=2026/09 step rotate-10 usage-log-rotate "$log"
  USAGE_LOG_LOCK_TIMEOUT=x step rotate-11 usage-log-rotate "$log"
  step daily-5 usage-daily-deltas "$home/elsewhere/usage-log.jsonl"
}

# --- Claude /usage polling ---------------------------------------------------

scenario_poll_usage() {
  local app usage
  app="$(app_dir)"
  usage="$work/usage"
  mkdir -p "$app" "$usage"
  cat > "$usage/full.txt" <<'OUT'
You are currently using your subscription to power your Claude Code usage

Current session: 22% used · resets Jul 22 at 8:50pm (Asia/Seoul)
Current week (all models): 5% used · resets Jul 29 at 2pm (Asia/Seoul)
Current week (Opus): 8% used · resets Jul 29 at 2pm (Asia/Seoul)

What's contributing to your limits usage?
OUT
  printf '%s\n' 'Current week (all models): 41% used · resets Aug 27 at 2pm (Asia/Seoul)' > "$usage/weekonly.txt"
  cat > "$usage/models.txt" <<'OUT'
Current session: 3% used
Current week (all models): 12% used · resets Jul 29 at 2pm (Asia/Seoul)
Current week (Opus): 4% used
Current week (Sonnet 5): 7% used · resets Jul 30 at 9:15am
Current week (Opus): 6% used
OUT
  cat > "$usage/variants.txt" <<'OUT'
  Current session:   45%   used   ·   resets jul 22 at 8:50 PM (America/Los_Angeles)
Current week (all models): 5% used · resets Feb 30 at 1pm (Asia/Seoul)
Current week (Haiku): 1% used · resets Jan 1 at 12am (Mars/Base)
Current week (Opus): 9% used · resets Dec 31 at 12pm
Current week ( All Models ): 6% used · resets Mar 9 at 7am (UTC)
OUT
  printf 'Current session: 30%% used · resets Oct 1 at 11:05am (Asia/Seoul)\r\nCurrent week (all models): 9%% used · resets Oct 3 at 1pm (Asia/Seoul)\r\n' > "$usage/crlf.txt"
  printf '%s\n' 'Failed to authenticate: OAuth session expired and could not be refreshed' > "$usage/auth.txt"
  printf '%s\n' 'Error: Please Run /Login to continue' > "$usage/auth-case.txt"
  printf '%s\n' "You are currently using your subscription" "" "Last 24h · 104 requests · 3 sessions" > "$usage/nolimits.txt"
  printf '%s\n' 'Current session: unknown' 'Current week (all models): n/a' > "$usage/parsefail.txt"
  : > "$usage/empty.txt"

  claude_poll() {  # claude_poll <name> <fixture> [VAR=value...]
    local name="$1" fixture="$2"
    shift 2
    local saved_path="$PATH"
    export PATH="$fakes:$PATH" FAKE_USAGE_FILE="$usage/$fixture" FAKE_CALL_LOG="$home/_out/calls"
    local assignment
    for assignment in "$@"; do export "$assignment"; done
    step "poll-$name" poll-usage
    for assignment in "$@"; do unset "${assignment%%=*}"; done
    export PATH="$saved_path"
    unset FAKE_USAGE_FILE FAKE_CALL_LOG
    keep "$step_number-$name" "$app/snapshot.json" "$app/claude-collector-state.json" "$app/.usage-raw.txt"
  }

  mkdir -p "$home/_out"
  printf '%s' '{"capturedAt": 1, "fiveHour": {"used_percentage": 50, "resets_at": 1700000000, "extra": "kept"}, "model": "Opus", "raw_rate_limits": {"x": 1}, "sevenDayOpus": null}' > "$app/snapshot.json"
  claude_poll full full.txt
  claude_poll weekonly weekonly.txt
  claude_poll models models.txt
  claude_poll variants variants.txt
  claude_poll crlf crlf.txt
  claude_poll auth auth.txt
  claude_poll auth-case auth-case.txt
  claude_poll nolimits nolimits.txt
  claude_poll parsefail parsefail.txt
  claude_poll empty empty.txt
  claude_poll missing full.txt CLAUDE_BIN="$home/no-such-claude"
  claude_poll signed-out full.txt 'FAKE_AUTH={"loggedIn": false, "authMethod": "none"}'
  claude_poll auth-text full.txt 'FAKE_AUTH=Logged in as someone'
  claude_poll auth-array full.txt 'FAKE_AUTH=[1,2]'
  printf '%s' '{broken' > "$app/snapshot.json"
  claude_poll broken-snapshot full.txt
  printf '%s' '[1,2,3]' > "$app/snapshot.json"
  claude_poll array-snapshot models.txt
}

# --- Codex app-server polling ------------------------------------------------

scenario_poll_codex() {
  local app
  app="$(app_dir)"
  mkdir -p "$home/_out"

  codex_poll() {  # codex_poll <name> <mode> [VAR=value...]
    local name="$1" mode="$2"
    shift 2
    export CODEX_BIN="$fakes/codex" FAKE_CODEX_MODE="$mode" FAKE_CODEX_INPUT="$home/_out/codex-input"
    local assignment
    for assignment in "$@"; do export "$assignment"; done
    step "codex-$name" poll-codex-usage
    for assignment in "$@"; do unset "${assignment%%=*}"; done
    unset CODEX_BIN FAKE_CODEX_MODE FAKE_CODEX_INPUT
    keep "$step_number-$name" "$app/codex-snapshot.json"
  }

  codex_poll ok ok
  codex_poll usage-error usage-error
  codex_poll rate-error rate-error
  codex_poll slow-init slow-init
  printf '%s' '{broken' > "$app/codex-snapshot.json"
  codex_poll broken-previous ok
  rm -f "$app/codex-snapshot.json"
  codex_poll no-previous usage-error
  if [ ! -e /opt/homebrew/bin/codex ] && [ ! -e /usr/local/bin/codex ]; then
    local saved_path="$PATH"
    export PATH="/usr/bin:/bin"
    codex_poll missing ok CODEX_BIN="$home/no-such-codex"
    export PATH="$saved_path"
  fi
}

# --- statusLine bridge -------------------------------------------------------

scenario_statusline() {
  local app inputs
  app="$(app_dir)"
  inputs="$work/statusline"
  mkdir -p "$inputs" "$home/_out"
  printf '%s\n\n' '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":22.5,"resets_at":1793235000},"seven_day":{"used_percentage":5,"resets_at":1793800000},"seven_day_opus":{"used_percentage":8.0,"resets_at":1793800000}},"session_id":"abc"}' > "$inputs/full.json"
  printf '%s' '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1793235000},"seven_day":{"used_percentage":33.333333,"resets_at":1793800000}}}' > "$inputs/changed.json"
  printf '%s' '{"model":{"id":"claude-sonnet-5-5"},"session_id":"x","cost":{"total_cost_usd":0.12}}' > "$inputs/nolimits.json"
  printf '%s' 'not json' > "$inputs/invalid.json"
  printf '%s' 'null' > "$inputs/null.json"
  printf '%s' '[1,2]' > "$inputs/array.json"
  printf '%s' '{"rate_limits":"oops","model":{"display_name":"X"}}' > "$inputs/string-limits.json"
  printf '%s' '{"rate_limits":{"seven_day":{"used_percentage":40}}} {"rate_limits":{"five_hour":{"used_percentage":2}}}' > "$inputs/two.json"
  printf '%s' '{"model":"plain","rate_limits":{"five_hour":{"used_percentage":1}}}' > "$inputs/model-string.json"
  : > "$inputs/empty.json"

  status_line() {  # status_line <name> <input> [VAR=value...]
    local name="$1" input="$2"
    shift 2
    local assignment
    for assignment in "$@"; do export "$assignment"; done
    step "status-$name" statusline < "$inputs/$input"
    for assignment in "$@"; do unset "${assignment%%=*}"; done
    keep "$step_number-$name" "$app/snapshot.json" "$app/snapshot.json.tmp" "$app/.claude-history.sig"
  }

  status_line full full.json
  status_line same full.json
  status_line changed changed.json
  status_line nolimits nolimits.json
  status_line invalid invalid.json
  status_line null null.json
  status_line array array.json
  status_line string-limits string-limits.json
  status_line two two.json
  status_line two-again two.json CLAUDEPACE_HISTORY_INTERVAL=0
  status_line model-string model-string.json
  status_line empty empty.json
}

# Not a parity case: replies that arrive in one burst. The old poller is
# expected to lose the second line here; this records what each one did.
burst_check() {
  local impl statuses=""
  for impl in legacy new; do
    home="$work/burst-$impl"
    rm -rf "$home"
    mkdir -p "$home"
    step_number=0
    CODEX_BIN="$fakes/codex" FAKE_CODEX_MODE=burst step burst poll-codex-usage
    statuses="$statuses $impl:$(sed -n 's/.*exit=//p' "$home/_out/transcript")"
  done
  echo "codex replies in one burst ->$statuses"
  echo "replies in one burst -> exit$statuses" > "$work/burst.txt"
  annotate notice "codex burst" "$work/burst.txt"
}

run_scenario scenario_ingest_codex
run_scenario scenario_ingest_claude
run_scenario scenario_ledger
run_scenario scenario_poll_usage
run_scenario scenario_poll_codex
run_scenario scenario_statusline
burst_check

[ -f "$work/digest.txt" ] && annotate notice "parity" "$work/digest.txt"

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures parity scenario(s) differ" >&2
  exit 1
fi
echo "PASS: Swift collectors match the legacy scripts on every scenario"
