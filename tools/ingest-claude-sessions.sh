#!/bin/bash
# Append Claude Code / Agent SDK session token usage to ClaudePace's usage log.
# Local-only: reads ~/.claude/projects/**/*.jsonl (terminal CLI + Agent Client/ACP
# + SDK subagents) and normalizes each assistant turn's token usage.
#
# WHY: the statusLine bridge only fires in a terminal Claude Code TUI, so usage
# from the Obsidian Agent Client (ACP, entrypoint "sdk-ts") is invisible to the
# menu bar. Those turns still land in ~/.claude/projects/**/*.jsonl with a full
# `message.usage` block — this adapter captures them, mirroring the Codex one.
#
# Mirrors tools/ingest-codex-sessions.sh: per-file byte offsets + seen event_ids
# make it idempotent and incremental. rate_limits are NOT here (statusLine only),
# so `rateLimits` is null; this is the token-usage axis, not the quota-% axis.

set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
appdir="$HOME/Library/Application Support/ClaudePace"
projects_dir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
usage_log_path="$appdir/usage-log.jsonl"
seen="$appdir/.claude-session-seen"
offset_dir="$appdir/.claude-session-offsets"
days="${CLAUDE_USAGE_MTIME_DAYS:-2}"
rotation_script="$script_dir/usage-log-rotate.sh"
lock_path="$appdir/.usage-log.lock"
lock_timeout="${USAGE_LOG_LOCK_TIMEOUT:-120}"

mkdir -p "$appdir" "$offset_dir" 2>/dev/null
touch "$usage_log_path" "$seen" 2>/dev/null

if [ ! -d "$projects_dir" ]; then
  echo "claude projects dir missing: $projects_dir" >&2
  exit 0
fi

case "$days" in ''|*[!0-9]*) days=2 ;; esac
case "$lock_timeout" in ''|*[!0-9]*) lock_timeout=120 ;; esac

if ! "$rotation_script" "$usage_log_path" >/dev/null; then
  echo "usage-log rotation check failed; continuing without discarding source events" >&2
fi

exec 9>>"$lock_path" || exit 73
if ! /usr/bin/lockf -s -t "$lock_timeout" 9; then
  echo "timed out waiting for usage-log lock: $lock_path" >&2
  exit 75
fi

scanned_count=0
added_count=0

while IFS= read -r file; do
  [ -f "$file" ] || continue
  scanned_count=$((scanned_count + 1))

  size=$(wc -c < "$file" | tr -d ' ')
  key=$(printf '%s' "$file" | shasum -a 256 | awk '{print $1}')
  offset_file="$offset_dir/$key.offset"
  offset=$(cat "$offset_file" 2>/dev/null)
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
  if [ "$offset" -gt "$size" ]; then
    offset=0
  fi
  if [ "$offset" -eq "$size" ]; then
    continue
  fi

  # Only assistant turns carry a usage block; grep-prefilter keeps jq calls low.
  tail -c +"$((offset + 1))" "$file" 2>/dev/null | grep '"type":"assistant"' | while IFS= read -r json; do
    printf '%s' "$json" | jq -e '.message.usage != null and (.message.usage.output_tokens != null)' >/dev/null 2>&1 || continue

    # requestId is unique per API call → dedupe key. Fall back to message.id, then timestamp.
    rid=$(printf '%s' "$json" | jq -r '(.requestId // .message.id // .timestamp // empty)' 2>/dev/null)
    timestamp=$(printf '%s' "$json" | jq -r '.timestamp // empty' 2>/dev/null)
    [ -n "$rid" ] || continue
    [ -n "$timestamp" ] || continue

    event_id="claude-session:$(printf '%s:%s' "$file" "$rid" | shasum -a 256 | awk '{print $1}')"
    if grep -qx "$event_id" "$seen" 2>/dev/null; then
      continue
    fi

    record=$(printf '%s' "$json" | jq -c \
      --arg event_id "$event_id" \
      --arg source_path "$file" '
      {
        schema: "usage.v1",
        source: "claude-session",
        event_id: $event_id,
        capturedAt: (((.timestamp // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null),
        timestamp: (.timestamp // null),
        model: (.message.model // null),
        entrypoint: (.entrypoint // null),
        tokenUsage: {
          input_tokens: (.message.usage.input_tokens // 0),
          output_tokens: (.message.usage.output_tokens // 0),
          cache_creation_input_tokens: (.message.usage.cache_creation_input_tokens // 0),
          cache_read_input_tokens: (.message.usage.cache_read_input_tokens // 0)
        },
        rateLimits: null,
        sourcePath: $source_path
      }' 2>/dev/null)

    [ -n "$record" ] || continue
    printf '%s\n' "$record" >> "$usage_log_path"
    printf '%s\n' "$event_id" >> "$seen"
  done

  printf '%s' "$size" > "$offset_file" 2>/dev/null
done < <(find "$projects_dir" -type f -name '*.jsonl' -mtime "-$days" -print 2>/dev/null | sort)

exec 9>&-

if ! "$rotation_script" "$usage_log_path" >/dev/null; then
  echo "post-ingest usage-log rotation check failed" >&2
fi

echo "scanned_files=$scanned_count history=$usage_log_path"
