#!/bin/bash
# Command-line routing of the ClaudePace executable. A command runs and exits;
# anything that is not a command must exit with a usage error (64) instead of
# starting another menu bar app — a mistyped statusLine command would otherwise
# spawn one on every render.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
bin="${CLAUDE_PACE_BIN:-$repo_dir/.build/release/ClaudePace}"
[ -x "$bin" ] || { echo "build first: swift build -c release (or set CLAUDE_PACE_BIN)" >&2; exit 1; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/claudepace-cli-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home"

failures=0
fail() {
  failures=$((failures + 1))
  echo "FAIL: $*" >&2
}

# run_bounded <seconds> <args...>: run with a throwaway HOME. A process still
# alive after <seconds> (that is, the menu bar app) is killed: status 124.
run_bounded() {
  local limit="$1"
  shift
  HOME="$scratch/home" "$bin" "$@" </dev/null >"$scratch/out" 2>"$scratch/err" &
  local pid=$!
  local ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 10)) ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

for argument in no-such-command statusLine poll_usage --version; do
  run_bounded 10 "$argument"
  status=$?
  [ "$status" -eq 64 ] || fail "'$argument' exited $status, expected 64 (124: still running, the app started)"
  grep -q -- "unknown command: $argument" "$scratch/err" || fail "'$argument': no usage error on stderr"
  [ ! -s "$scratch/out" ] || fail "'$argument': wrote to stdout"
done

run_bounded 10 help
status=$?
[ "$status" -eq 0 ] || fail "help exited $status"
grep -q '^usage: ClaudePace' "$scratch/out" || fail "help: no usage text on stdout"

# A real command still runs to completion.
run_bounded 30 usage-history-summary
status=$?
[ "$status" -eq 0 ] || fail "usage-history-summary exited $status"
grep -q '"records": 0' "$scratch/out" || fail "usage-history-summary: unexpected output: $(head -c 300 "$scratch/out")"

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures command-line assertions failed" >&2
  exit 1
fi
echo "PASS: command-line routing"
