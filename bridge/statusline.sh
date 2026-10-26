#!/bin/bash
# ClaudePace bridge — runs as a Claude Code statusLine command.
# Claude Code pipes a JSON blob (incl. `rate_limits`) on stdin every render.
# We capture it and write a snapshot the ClaudePace menu bar app reads.
# Must stay fast: no network, single stdin read, jq only.

input=$(cat)

script_dir=$(cd "$(dirname "$0")" && pwd)
appdir="$HOME/Library/Application Support/ClaudePace"
debugdir="$HOME/Developer/claude-pace/.debug"
snap="$appdir/snapshot.json"
usage_log_path="$appdir/usage-log.jsonl"
history_sig="$appdir/.claude-history.sig"
history_ts="$appdir/.claude-history.ts"
rotation_script="$script_dir/../tools/usage-log-rotate.sh"
lock_path="$appdir/.usage-log.lock"
lock_timeout="${USAGE_LOG_LOCK_TIMEOUT:-120}"
mkdir -p "$appdir" "$debugdir" 2>/dev/null

# 1) raw dump — lets us see the exact schema Claude Code sends (verification).
printf '%s' "$input" > "$debugdir/last-input.json" 2>/dev/null

# 2) snapshot (atomic). Robust to missing fields / non-JSON input.
now=$(date +%s)
if printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  printf '%s' "$input" | jq --argjson now "$now" '
    (.rate_limits // {}) as $rl | {
      capturedAt:     $now,
      fiveHour:       $rl.five_hour,
      sevenDay:       $rl.seven_day,
      sevenDayOpus:   $rl.seven_day_opus,
      sevenDaySonnet: $rl.seven_day_sonnet,
      model:          (.model.display_name // .model.id),
      raw_rate_limits: $rl
    }' > "$snap.tmp" 2>/dev/null && mv -f "$snap.tmp" "$snap" 2>/dev/null

  sig=$(printf '%s' "$input" | jq -c '[.model.display_name // .model.id // null, .rate_limits // {}]' 2>/dev/null | shasum -a 256 | awk '{print $1}')
  interval="${CLAUDEPACE_HISTORY_INTERVAL:-300}"
  case "$interval" in ''|*[!0-9]*) interval=300 ;; esac
  case "$lock_timeout" in ''|*[!0-9]*) lock_timeout=120 ;; esac

  if [ -x "$rotation_script" ]; then
    "$rotation_script" "$usage_log_path" >/dev/null 2>&1
  fi

  exec 9>>"$lock_path"
  if /usr/bin/lockf -s -t "$lock_timeout" 9; then
    last_sig=$(cat "$history_sig" 2>/dev/null)
    last_ts=$(cat "$history_ts" 2>/dev/null)
    case "$last_ts" in ''|*[!0-9]*) last_ts=0 ;; esac

    if [ "$sig" != "$last_sig" ] || [ $((now - last_ts)) -ge "$interval" ]; then
      if printf '%s' "$input" | jq -c --argjson now "$now" --arg sig "$sig" '
        {
          schema: "usage.v1",
          source: "claude-statusline",
          event_id: ("claude-statusline:" + ($now | tostring) + ":" + $sig),
          capturedAt: $now,
          timestamp: ($now | todateiso8601),
          model: (.model.display_name // .model.id // null),
          rateLimits: (.rate_limits // {}),
          tokenUsage: null,
          sourcePath: "Claude Code statusLine"
        }' >> "$usage_log_path" 2>/dev/null; then
        printf '%s' "$sig" > "$history_sig" 2>/dev/null
        printf '%s' "$now" > "$history_ts" 2>/dev/null
      fi
    fi
  fi
  exec 9>&-

  if [ -x "$rotation_script" ]; then
    "$rotation_script" "$usage_log_path" >/dev/null 2>&1
  fi
fi

# 3) statusline text (secondary — the menu bar app is the real UI).
sev=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
fiv=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
if [ -n "$sev" ] || [ -n "$fiv" ]; then
  out="⏱ AI Usage · Claude"
  [ -n "$sev" ] && out="$out · 주 ${sev%.*}%"
  [ -n "$fiv" ] && out="$out · 5h ${fiv%.*}%"
else
  out="⏱ AI Usage · Claude (rate_limits 대기…)"
fi
printf '%s' "$out"
