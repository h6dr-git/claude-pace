#!/bin/bash
# `ClaudePace menu-preview`: the menu the app would show, as text, for a
# throwaway HOME. Fixture capture and reset times are relative to now, so
# freshness and resets never flip under the test. The preview must only read:
# no app, no poll, no file written.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
bin="${CLAUDE_PACE_BIN:-$repo_dir/.build/release/ClaudePace}"
[ -x "$bin" ] || { echo "build first: swift build -c release (or set CLAUDE_PACE_BIN)" >&2; exit 1; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/claudepace-menu-preview-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

home="$scratch/home"
app="$home/Library/Application Support/ClaudePace"
mkdir -p "$app"
out="$scratch/out"
err="$scratch/err"

failures=0
fail() {
  failures=$((failures + 1))
  echo "FAIL: $*" >&2
}

# preview <provider> [home]: run menu-preview ("unset": with no
# AI_USAGE_PRIMARY_PROVIDER at all). A process still alive after 10s is the
# menu bar app starting instead: status 124.
preview() {
  local provider="$1" target="${2:-$home}"
  if [ "$provider" = unset ]; then
    env -u AI_USAGE_PRIMARY_PROVIDER HOME="$target" "$bin" menu-preview </dev/null >"$out" 2>"$err" &
  else
    HOME="$target" AI_USAGE_PRIMARY_PROVIDER="$provider" "$bin" menu-preview </dev/null >"$out" 2>"$err" &
  fi
  local pid=$! ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge 100 ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      status=124
      return
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
  status=$?
}

# check_run <case>: the preview exited cleanly and quietly.
check_run() {
  [ "$status" -eq 0 ] || fail "$1: exited $status (124: still running, the app started)"
  [ ! -s "$err" ] || fail "$1: wrote to stderr: $(head -c 300 "$err")"
}
line() { grep -qxF -- "$2" "$out" || fail "$1: missing line: $2"; }
prefix() {
  awk -v p="$2" 'index($0, p) == 1 { found = 1 } END { exit found ? 0 : 1 }' "$out" \
    || fail "$1: no line starting with: $2"
}
absent() {
  if grep -qF -- "$2" "$out"; then fail "$1: unexpected: $2"; fi
}
no_line() {
  if grep -qxF -- "$2" "$out"; then fail "$1: unexpected line: $2"; fi
}
# above <case> <a> <b>: every line starting with <a> comes before the first
# line starting with <b>, and both are there.
above() {
  awk -v a="$2" -v b="$3" '
    index($0, a) == 1 { last_a = NR }
    index($0, b) == 1 && !first_b { first_b = NR }
    END { exit (last_a && first_b && last_a < first_b) ? 0 : 1 }' "$out" \
    || fail "$1: \"$2\" is not above \"$3\""
}
# tidy <case>: no separator right under the first line (the block's header),
# and never two in a row.
tidy() {
  awk 'NR == 2 && $0 == "—" { bad = 1 } prev == "—" && $0 == "—" { bad = 1 } { prev = $0 } END { exit bad }' "$out" \
    || fail "$1: a separator right under the header, or two in a row"
}
# dump <case> <failures before>: show the preview of a case that failed.
dump() {
  [ "$failures" -eq "$2" ] || { echo "--- $1 preview:" >&2; cat "$out" >&2; }
}

# Every path, size, mtime and content hash under a directory.
manifest() {
  (cd "$1" && find . -print | LC_ALL=C sort \
    && find . -type f -exec stat -f '%m %z %N' {} + | LC_ALL=C sort \
    && find . -type f -exec shasum {} + | LC_ALL=C sort)
}

month_day() {
  python3 -c 'import datetime, sys; d = datetime.datetime.fromtimestamp(int(sys.argv[1])); print(f"{d.month}/{d.day}")' "$1"
}
clock() {
  python3 -c 'import datetime, sys; d = datetime.datetime.fromtimestamp(int(sys.argv[1])); print(f"{d.month}/{d.day} {d.hour:02d}:{d.minute:02d}")' "$1"
}

now="$(date +%s)"
captured=$((now - 60))
week_reset=$((now + 28 * 3600))
absent_since=$((now - 3 * 86400))

write_state() {
  printf '{"schema": "claude-collector-state.v1", "status": "ok", "capturedAt": %s, "detail": ""}\n' "$1" \
    > "$app/claude-collector-state.json"
}

# An Ultra account after 2026-10-30: weekly limits only, Fable the tightest.
write_ultra() {
  cat > "$app/snapshot.json" <<JSON
{"capturedAt": $captured, "fiveHour": null, "fiveHourAbsentSince": $absent_since,
 "sevenDay": {"used_percentage": 60, "resets_at": $week_reset}, "sevenDayOpus": null, "sevenDaySonnet": null,
 "model": "Opus 5 (1M context)", "raw_rate_limits": {},
 "modelWindows": {"Fable": {"used_percentage": 91, "resets_at": $week_reset}}, "source": "usage-poll"}
JSON
  write_state "$captured"
}

# --- 1) no 5-hour limit: one line instead of the ended-window text, Fable drives the ring
write_ultra
rm -f "$app/settings.json"
before="$(manifest "$home")"
mark=$failures
preview claude
check_run "ultra"
line "ultra" "5시간 한도 없는 계정 · 주간 한도만 적용 ($(month_day "$absent_since") 확인)"
line "ultra" "Fable 주간 · 링"
line "ultra" "주간 전체 (7일)"
prefix "ultra" "[■■■■■■■■■□] 사용 91% · 예상 "
prefix "ultra" "[■■■■■■□□□□] 사용 60% · 예상 "
prefix "ultra" "남은 40% · 리셋까지 하루 "
prefix "ultra" "남은 9% · 리셋까지 하루 "
line "ultra" "메뉴바 링 ▸ ✓자동 (가장 많이 쓴 한도) | 주간 전체 | Fable 주간"
line "ultra" "ring: Fable 주간 91%"
prefix "ultra" "tooltip: AI Usage · Claude · 링 Fable 주간 91% · 주 60%"
line "ultra" "1분 전 갱신"
absent "ultra" "다음 메시지부터"
absent "ultra" "창 끝남"
absent "ultra" "지금 열린 창 없음"
absent "ultra" "Opus 5 (1M context)"
absent "ultra" "모델별 주간"
absent "ultra" "갱신 멈춤"
# The note comes once, after the limits that do apply: below the bucket's
# last line (its planning line), not between the week and the bucket.
above "ultra" "Fable 주간 · 링" "5시간 한도 없는 계정 · 주간 한도만 적용"
above "ultra" "남은 9% · 리셋까지 하루 " "5시간 한도 없는 계정 · 주간 한도만 적용"
[ "$(grep -c '^5시간 한도 없는 계정' "$out")" -eq 1 ] || fail "ultra: the note is not there exactly once"
tidy "ultra"
[ "$(manifest "$home")" = "$before" ] || fail "ultra: menu-preview changed files under HOME"
dump "ultra" "$mark"

# --- 2) a pinned window without a reading falls back to auto, and says so
printf '{"schema":"claudepace-settings.v1","ring":"five"}\n' > "$app/settings.json"
before="$(manifest "$home")"
mark=$failures
preview claude
check_run "pinned five"
line "pinned five" "링: 5시간 지금 값 없음 · 자동으로 표시"
line "pinned five" "ring: Fable 주간 91%"
line "pinned five" "Fable 주간 · 링"
line "pinned five" "메뉴바 링 ▸ 자동 (가장 많이 쓴 한도) | 주간 전체 | Fable 주간 | ✓5시간 (지금 값 없음)"
[ "$(manifest "$home")" = "$before" ] || fail "pinned five: menu-preview changed files under HOME"
dump "pinned five" "$mark"

# --- 3) a pinned window with a reading is kept, even below another
printf '{"schema":"claudepace-settings.v1","ring":"week"}\n' > "$app/settings.json"
mark=$failures
preview claude
check_run "pinned week"
line "pinned week" "주간 전체 (7일) · 링"
line "pinned week" "Fable 주간"
line "pinned week" "ring: 주간 전체 60%"
line "pinned week" "메뉴바 링 ▸ 자동 (가장 많이 쓴 한도) | ✓주간 전체 | Fable 주간"
prefix "pinned week" "tooltip: AI Usage · Claude · 링 주간 전체 60%"
absent "pinned week" "링: "
dump "pinned week" "$mark"

# --- 4) an unreadable settings file means auto
printf '{not json' > "$app/settings.json"
mark=$failures
preview claude
check_run "garbage settings"
line "garbage settings" "ring: Fable 주간 91%"
absent "garbage settings" "링: "
dump "garbage settings" "$mark"
rm -f "$app/settings.json"

# --- 5) a Pro-style account keeps its 5-hour window
five_reset=$((now + 9000))
cat > "$app/snapshot.json" <<JSON
{"capturedAt": $captured, "fiveHour": {"used_percentage": 22, "resets_at": $five_reset},
 "sevenDay": {"used_percentage": 5, "resets_at": $((now + 3 * 86400))}, "sevenDayOpus": null,
 "sevenDaySonnet": null, "model": "Opus 5", "source": "usage-poll"}
JSON
mark=$failures
preview claude
check_run "pro"
line "pro" "5시간 · 링"
line "pro" "[■■□□□□□□□□] 사용 22%"
prefix "pro" "리셋까지 2시간 "
line "pro" "메뉴바 링 ▸ ✓자동 (가장 많이 쓴 한도) | 주간 전체 | 5시간"
line "pro" "ring: 5시간 22%"
line "pro" "tooltip: AI Usage · Claude · 링 5시간 22% · 주 5%"
absent "pro" "5시간 한도 없는 계정"
tidy "pro"
dump "pro" "$mark"

# --- 6) the snapshot as stored before the collector knew: today's ended-window
# text stays, but the ring already skips the ended 5-hour window
five_ended=$((now - 3 * 86400))
cat > "$app/snapshot.json" <<JSON
{"capturedAt": $captured, "fiveHour": {"used_percentage": 9, "resets_at": $five_ended},
 "sevenDay": {"used_percentage": 60, "resets_at": $week_reset}, "sevenDayOpus": null, "sevenDaySonnet": null,
 "model": "Opus 5 (1M context)", "raw_rate_limits": {},
 "modelWindows": {"Fable": {"used_percentage": 91, "resets_at": $week_reset}}, "source": "usage-poll"}
JSON
mark=$failures
preview claude
check_run "ended 5h, no key"
line "ended 5h, no key" "지금 열린 창 없음 ($(clock "$five_ended")에 끝남) · 다음 메시지부터 새로 시작"
line "ended 5h, no key" "ring: Fable 주간 91%"
absent "ended 5h, no key" "사용 9%"
dump "ended 5h, no key" "$mark"

# --- 7) an old reading is flagged, the ring dimmed (tooltip), with the last attempt
old=$((now - 1800))
write_ultra
python3 - "$app/snapshot.json" "$old" <<'PY'
import json, sys
path, captured = sys.argv[1], int(sys.argv[2])
snapshot = json.load(open(path))
snapshot["capturedAt"] = captured
json.dump(snapshot, open(path, "w"))
PY
write_state "$old"
mark=$failures
preview claude
check_run "stale"
line "stale" "⚠ 갱신 멈춤"
line "stale" "마지막 조회 시도 30분 전"
prefix "stale" "tooltip: AI Usage · Claude · 링 Fable 주간 91%"
grep -q ' · 갱신 멈춤$' "$out" || fail "stale: tooltip does not say the reading stopped"
dump "stale" "$mark"

# --- 8) another provider: Claude is a secondary block with no ring of its own
write_ultra
mark=$failures
preview codex
check_run "codex mode"
line "codex mode" "Codex 스냅샷 없음 · 기본 링에서 제외"
line "codex mode" "Claude · 전환 보조"
line "codex mode" "Fable 주간"
line "codex mode" "ring: ?"
absent "codex mode" "메뉴바 링"
absent "codex mode" " · 링"
dump "codex mode" "$mark"

# --- 9) an empty HOME: the reason instead of a number, and still nothing written
empty="$scratch/empty"
mkdir -p "$empty"
mark=$failures
preview claude "$empty"
check_run "empty home"
line "empty home" "Claude"
line "empty home" "스냅샷 없음 · 아직 한 번도 수집되지 않음"
line "empty home" "ring: ?"
line "empty home" "tooltip: Claude 사용량: 공식 조회값 없음"
# Only windows with a reading are offered, the all-models week included.
line "empty home" "메뉴바 링 ▸ ✓자동 (가장 많이 쓴 한도)"
[ -z "$(find "$empty" -mindepth 1 -print)" ] || fail "empty home: menu-preview created files"
dump "empty home" "$mark"

# --- 10) a reset no official source prints (1e19) is no reading, not a crash
cat > "$app/snapshot.json" <<JSON
{"capturedAt": $captured, "fiveHour": null, "fiveHourAbsentSince": $absent_since,
 "sevenDay": {"used_percentage": 60, "resets_at": $week_reset}, "sevenDayOpus": null, "sevenDaySonnet": null,
 "modelWindows": {"Fable": {"used_percentage": 50, "resets_at": 1e19}}, "source": "usage-poll"}
JSON
write_state "$captured"
mark=$failures
preview claude
check_run "absurd bucket reset"
line "absurd bucket reset" "주간 전체 (7일) · 링"
line "absurd bucket reset" "ring: 주간 전체 60%"
line "absurd bucket reset" "메뉴바 링 ▸ ✓자동 (가장 많이 쓴 한도) | 주간 전체"
absent "absurd bucket reset" "Fable"
dump "absurd bucket reset" "$mark"

# --- 11) an absurd last-attempt time under an old reading: no age, not a crash
cat > "$app/snapshot.json" <<JSON
{"capturedAt": $old, "fiveHour": null, "fiveHourAbsentSince": $absent_since,
 "sevenDay": {"used_percentage": 60, "resets_at": $week_reset}, "sevenDayOpus": null, "sevenDaySonnet": null,
 "modelWindows": {"Fable": {"used_percentage": 91, "resets_at": $week_reset}}, "source": "usage-poll"}
JSON
write_state 1e19
mark=$failures
preview claude
check_run "absurd attempt time"
line "absurd attempt time" "⚠ 갱신 멈춤"
line "absurd attempt time" "마지막 조회 시도 ? 전"
line "absurd attempt time" "ring: Fable 주간 91%"
dump "absurd attempt time" "$mark"

# --- 12) a leftover codex-snapshot.json holding absurd numbers costs the other
# modes nothing (it used to trap them on its way to Int); Codex mode itself
# shows "?" for such numbers. A fresh capture time: the runs compared below
# must not straddle a minute of "N분 전 갱신".
captured=$(($(date +%s) - 60))
write_ultra
rm -f "$app/codex-snapshot.json"
preview claude
check_run "claude, no codex file"
cp "$out" "$scratch/claude-plain"
preview unset
check_run "no provider, no codex file"
cp "$out" "$scratch/unset-plain"
cat > "$app/codex-snapshot.json" <<'JSON'
{"schema": "codex-usage.v1", "source": "codex-app-server", "capturedAt": 1e19,
 "rateLimits": {"limitId": "codex", "planType": "pro",
   "primary": {"usedPercent": 1e19, "windowDurationMins": 1e19, "resetsAt": 1e19},
   "secondary": {"usedPercent": -1e19, "windowDurationMins": -1e19, "resetsAt": -1e19}}}
JSON
mark=$failures
preview claude
check_run "absurd codex file, claude mode"
cmp -s "$out" "$scratch/claude-plain" \
  || fail "absurd codex file, claude mode: output changed: $(diff "$scratch/claude-plain" "$out" | head -6)"
preview unset
check_run "absurd codex file, no provider"
cmp -s "$out" "$scratch/unset-plain" \
  || fail "absurd codex file, no provider: output changed: $(diff "$scratch/unset-plain" "$out" | head -6)"
line "absurd codex file, no provider" "Grok"
preview codex
check_run "absurd codex file, codex mode"
line "absurd codex file, codex mode" "Codex 스냅샷이 10분을 넘어 기본 링에서 제외"
line "absurd codex file, codex mode" "ring: ?"
dump "absurd codex file" "$mark"

# A fresh capture, so the Codex rows are built from those numbers.
cat > "$app/codex-snapshot.json" <<JSON
{"schema": "codex-usage.v1", "source": "codex-app-server", "capturedAt": $(($(date +%s) - 60)),
 "rateLimits": {"limitId": "codex", "planType": "pro",
   "primary": {"usedPercent": 1e19, "windowDurationMins": 1e19, "resetsAt": 1e19},
   "secondary": {"usedPercent": 50, "windowDurationMins": 10080, "resetsAt": -1e19}}}
JSON
mark=$failures
preview codex
check_run "absurd codex windows"
line "absurd codex windows" "Codex · Pro"
line "absurd codex windows" "전체 · ?"
prefix "absurd codex windows" "[■■■■■■■■■■] 사용 ? · 예상 ? "
line "absurd codex windows" "리셋까지 ? (?)"
prefix "absurd codex windows" "[■■■■■□□□□□] 사용 50%"
line "absurd codex windows" "1분 전 갱신"
line "absurd codex windows" "tooltip: AI Usage · Codex ?"
dump "absurd codex windows" "$mark"
rm -f "$app/codex-snapshot.json"

# --- 13) windows the latest poll did not print (percentage blanked, reset kept,
# fiveHourSeenAt added): no reading, so no bar and no ended text. The 5-hour
# section says why it has no number instead of going missing; a pinned week
# falls back while staying listed, greyed out
cat > "$app/snapshot.json" <<JSON
{"capturedAt": $captured, "fiveHour": {"used_percentage": null, "resets_at": $five_reset},
 "fiveHourSeenAt": $((captured - 3600)),
 "sevenDay": {"used_percentage": null, "resets_at": $week_reset}, "sevenDayOpus": null, "sevenDaySonnet": null,
 "modelWindows": {"Fable": {"used_percentage": 91, "resets_at": $week_reset}}, "source": "usage-poll"}
JSON
write_state "$captured"
printf '{"schema":"claudepace-settings.v1","ring":"week"}\n' > "$app/settings.json"
mark=$failures
preview claude
check_run "blanked windows"
[ "$(sed -n 2p "$out")" = "5시간" ] || fail "blanked windows: the 5-hour section is not right under the header"
line "blanked windows" "사용률 값 없음 — 마지막 조회에 5시간 줄이 없음 (창은 $(clock "$five_reset")까지)"
above "blanked windows" "사용률 값 없음" "Fable 주간 · 링"
line "blanked windows" "링: 주간 전체 지금 값 없음 · 자동으로 표시"
line "blanked windows" "ring: Fable 주간 91%"
line "blanked windows" "메뉴바 링 ▸ 자동 (가장 많이 쓴 한도) | Fable 주간 | ✓주간 전체 (지금 값 없음)"
no_line "blanked windows" "주간 전체 (7일)"
absent "blanked windows" "5시간 · 링"
absent "blanked windows" "창 끝남"
absent "blanked windows" "리셋됨"
absent "blanked windows" "지금 열린 창 없음"
[ "$(grep -c '^\[' "$out")" -eq 1 ] || fail "blanked windows: a bar other than Fable's"
tidy "blanked windows"
rm -f "$app/settings.json"
dump "blanked windows" "$mark"

# ...and one the latest poll printed but could not read
cat > "$app/snapshot.json" <<JSON
{"capturedAt": $captured, "fiveHour": {"used_percentage": null, "resets_at": null},
 "fiveHourSeenAt": $captured,
 "sevenDay": {"used_percentage": 40, "resets_at": $week_reset}, "sevenDayOpus": null, "sevenDaySonnet": null,
 "source": "usage-poll"}
JSON
mark=$failures
preview claude
check_run "unreadable session line"
line "unreadable session line" "5시간"
line "unreadable session line" "사용률 값 없음 — 5시간 줄을 해석하지 못함"
above "unreadable session line" "주간 전체 (7일)" "5시간"
line "unreadable session line" "ring: 주간 전체 40%"
[ "$(grep -c '^\[' "$out")" -eq 1 ] || fail "unreadable session line: a bar other than the week's"
tidy "unreadable session line"
dump "unreadable session line" "$mark"

# --- 14) the last hour of a week: the time left instead of a per-hour rate
# larger than what is left (a fresh now: the reset is minutes away)
soon="$(date +%s)"
cat > "$app/snapshot.json" <<JSON
{"capturedAt": $((soon - 60)), "fiveHour": null, "fiveHourAbsentSince": $absent_since,
 "sevenDay": {"used_percentage": 64, "resets_at": $((soon + 570))}, "sevenDayOpus": null, "sevenDaySonnet": null,
 "source": "usage-poll"}
JSON
write_state "$((soon - 60))"
mark=$failures
preview claude
check_run "last hour"
line "last hour" "남은 36% · 리셋까지 9분"
absent "last hour" "시간당"
dump "last hour" "$mark"

# --- 15) a Codex window the app-server gave no percentage: said as such, not
# drawn as "사용 0%" with a projection made from that 0%; the other window
# keeps its bar. Its own HOME, so no Claude block sits underneath.
codex_home="$scratch/codex-home"
mkdir -p "$codex_home/Library/Application Support/ClaudePace"
fresh="$(date +%s)"
cat > "$codex_home/Library/Application Support/ClaudePace/codex-snapshot.json" <<JSON
{"schema": "codex-usage.v1", "source": "codex-app-server", "capturedAt": $((fresh - 60)),
 "rateLimits": {"limitId": "codex", "planType": "pro",
   "primary": {"usedPercent": null, "windowDurationMins": 300, "resetsAt": $((fresh + 3600))},
   "secondary": {"usedPercent": 50, "windowDurationMins": 10080, "resetsAt": $((fresh + 3 * 86400))}}}
JSON
mark=$failures
preview codex "$codex_home"
check_run "codex, no percentage"
[ "$(awk 'prev == "전체 · 5시간" { print; exit } { prev = $0 }' "$out")" = "사용률 값 없음 — 조회값에 퍼센트가 없음" ] \
  || fail "codex, no percentage: the 5-hour header is not followed by the no-value line"
line "codex, no percentage" "전체 · 7일"
prefix "codex, no percentage" "[■■■■■□□□□□] 사용 50% · 예상 "
[ "$(grep -c '^\[' "$out")" -eq 1 ] || fail "codex, no percentage: a bar other than the 7-day window's"
absent "codex, no percentage" "사용 0%"
absent "codex, no percentage" "예상 0%"
line "codex, no percentage" "ring: ?"
line "codex, no percentage" "tooltip: AI Usage · Codex"
dump "codex, no percentage" "$mark"

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures menu-preview assertions failed" >&2
  exit 1
fi
echo "PASS: menu-preview assertions"
