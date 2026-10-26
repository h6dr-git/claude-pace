#!/bin/bash
# Append Codex token_count events to ClaudePace's normalized usage log.
# Local-only: reads ~/.codex/sessions JSONL and writes Application Support.

set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
appdir="$HOME/Library/Application Support/ClaudePace"
sessions_dir="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
usage_log_path="$appdir/usage-log.jsonl"
seen="$appdir/.codex-usage-seen"
offset_dir="$appdir/.codex-offsets"
days="${CODEX_USAGE_MTIME_DAYS:-2}"
rotation_script="$script_dir/usage-log-rotate.sh"
lock_path="$appdir/.usage-log.lock"
lock_timeout="${USAGE_LOG_LOCK_TIMEOUT:-120}"

mkdir -p "$appdir" "$offset_dir" 2>/dev/null
touch "$usage_log_path" "$seen" 2>/dev/null

if [ ! -d "$sessions_dir" ]; then
  echo "codex sessions dir missing: $sessions_dir" >&2
  exit 0
fi

case "$days" in ''|*[!0-9]*) days=2 ;; esac
case "$lock_timeout" in ''|*[!0-9]*) lock_timeout=120 ;; esac

# The app invokes this adapter every 60 seconds. Rotate both before and after
# ingestion so an already-large ledger and a batch that crosses the limit are
# handled in the same pass.
if ! "$rotation_script" "$usage_log_path" >/dev/null; then
  echo "usage-log rotation check failed; continuing without discarding source events" >&2
fi

exec 9>>"$lock_path" || exit 73
if ! /usr/bin/lockf -s -t "$lock_timeout" 9; then
  echo "timed out waiting for usage-log lock: $lock_path" >&2
  exit 75
fi

scanned_count=0

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

  tail -c +"$((offset + 1))" "$file" 2>/dev/null | grep '"type":"token_count"' | while IFS= read -r json; do
    timestamp=$(printf '%s' "$json" | jq -r '.timestamp // empty' 2>/dev/null)
    [ -n "$timestamp" ] || continue
    total_tokens=$(printf '%s' "$json" | jq -r '.payload.info.total_token_usage.total_tokens // empty' 2>/dev/null)
    last_tokens=$(printf '%s' "$json" | jq -r '.payload.info.last_token_usage.total_tokens // empty' 2>/dev/null)

    event_id="codex-session:$(printf '%s:%s:%s:%s' "$file" "$timestamp" "$total_tokens" "$last_tokens" | shasum -a 256 | awk '{print $1}')"
    if grep -qx "$event_id" "$seen" 2>/dev/null; then
      continue
    fi

    record=$(printf '%s' "$json" | jq -c \
      --arg event_id "$event_id" \
      --arg source_path "$file" '
      {
        schema: "usage.v1",
        source: "codex-session",
        event_id: $event_id,
        capturedAt: (((.timestamp // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null),
        timestamp: (.timestamp // null),
        model: null,
        modelContextWindow: (.payload.info.model_context_window // null),
        tokenUsage: {
          total: (.payload.info.total_token_usage // null),
          last: (.payload.info.last_token_usage // null)
        },
        rateLimits: (.payload.rate_limits // null),
        sourcePath: $source_path
      }' 2>/dev/null)

    [ -n "$record" ] || continue
    printf '%s\n' "$record" >> "$usage_log_path"
    printf '%s\n' "$event_id" >> "$seen"
  done

  printf '%s' "$size" > "$offset_file" 2>/dev/null
done < <(find "$sessions_dir" -type f -name '*.jsonl' -mtime "-$days" -print 2>/dev/null | sort)

exec 9>&-

if ! "$rotation_script" "$usage_log_path" >/dev/null; then
  echo "post-ingest usage-log rotation check failed" >&2
fi

echo "scanned_files=$scanned_count history=$usage_log_path"
