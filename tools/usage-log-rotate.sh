#!/bin/bash
# Rotate the active usage ledger as one immutable segment.
# Source JSONL is moved only: never split, copied, compressed, or deleted.

set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
usage_log_path="${1:-$HOME/Library/Application Support/ClaudePace/usage-log.jsonl}"
usage_dir=$(dirname "$usage_log_path")
archive_dir="$usage_dir/archive"
period_marker="$usage_dir/.usage-log-active-period"
lock_path="$usage_dir/.usage-log.lock"
segment_summary_script="$script_dir/usage-log-segment-summary.sh"
max_bytes="${USAGE_LOG_MAX_BYTES:-52428800}"
current_period="${USAGE_LOG_CURRENT_PERIOD:-$(TZ=Asia/Seoul date '+%Y-%m')}"
lock_timeout="${USAGE_LOG_LOCK_TIMEOUT:-120}"

case "$max_bytes" in ''|*[!0-9]*) echo "invalid USAGE_LOG_MAX_BYTES: $max_bytes" >&2; exit 64 ;; esac
case "$current_period" in ????-??) ;; *) echo "invalid usage-log period: $current_period" >&2; exit 64 ;; esac
case "$lock_timeout" in ''|*[!0-9]*) echo "invalid USAGE_LOG_LOCK_TIMEOUT: $lock_timeout" >&2; exit 64 ;; esac

if [ ! -x "$segment_summary_script" ]; then
  echo "segment summary script is not executable: $segment_summary_script" >&2
  exit 69
fi

mkdir -p "$usage_dir" "$archive_dir" 2>/dev/null || {
  echo "cannot create usage-log directories under: $usage_dir" >&2
  exit 73
}

# A persistent lock file plus BSD lockf avoids stale dot-lock cleanup and makes
# mv atomic with respect to every in-repo writer.
exec 9>>"$lock_path" || exit 73
if ! /usr/bin/lockf -s -t "$lock_timeout" 9; then
  echo "timed out waiting for usage-log lock: $lock_path" >&2
  exit 75
fi

touch "$usage_log_path" 2>/dev/null || {
  echo "cannot create active usage log: $usage_log_path" >&2
  exit 73
}

write_segment_summary() {
  segment_file="$1"
  summary_file="$2"
  summary_label="$3"
  summary_temp="$summary_file.tmp.$$"

  segment_json=$("$segment_summary_script" "$segment_file" "$summary_label") || return 1
  printf '%s\n' "$segment_json" > "$summary_temp" || return 1
  mv "$summary_temp" "$summary_file" || return 1
}

# Repair only crash-interrupted, missing indexes. Existing indexes are immutable
# and are checked by the lightweight reader before use.
archived_segments=()
while IFS= read -r -d '' archived_segment; do
  archived_segments+=("$archived_segment")
done < <(find "$archive_dir" -maxdepth 1 -type f -name 'usage-log-*.jsonl' -print0 | sort -z)

if [ "${#archived_segments[@]}" -gt 0 ]; then
  for archived_segment in "${archived_segments[@]}"; do
    archived_summary="${archived_segment%.jsonl}.summary.json"
    if [ ! -f "$archived_summary" ]; then
      archived_name=$(basename "$archived_segment")
      write_segment_summary "$archived_segment" "$archived_summary" "archive/$archived_name" || {
        echo "cannot index archived usage segment: $archived_segment" >&2
        exit 65
      }
      echo "indexed archive=$archived_segment summary=$archived_summary"
    fi
  done
fi

active_period=$(cat "$period_marker" 2>/dev/null)
case "$active_period" in ????-??) ;; *) active_period="$current_period" ;; esac

active_bytes=$(wc -c < "$usage_log_path" | tr -d ' ')
case "$active_bytes" in ''|*[!0-9]*) echo "cannot measure active usage log" >&2; exit 74 ;; esac

rotation_reason=""
archive_period="$active_period"
if [ "$active_period" != "$current_period" ] && [ "$active_bytes" -gt 0 ]; then
  rotation_reason="month"
fi
if [ "$active_bytes" -gt "$max_bytes" ]; then
  if [ -n "$rotation_reason" ]; then
    rotation_reason="$rotation_reason+threshold"
  else
    rotation_reason="threshold"
  fi
fi

if [ -z "$rotation_reason" ]; then
  printf '%s\n' "$current_period" > "$period_marker"
  echo "rotation_not_needed bytes=$active_bytes maxBytes=$max_bytes period=$current_period"
  exit 0
fi

segment_number=1
while :; do
  segment_suffix=$(printf '%03d' "$segment_number")
  archive_path="$archive_dir/usage-log-$archive_period-$segment_suffix.jsonl"
  if [ ! -e "$archive_path" ]; then
    break
  fi
  segment_number=$((segment_number + 1))
done

archive_summary="${archive_path%.jsonl}.summary.json"
archive_name=$(basename "$archive_path")
segment_json=$("$segment_summary_script" "$usage_log_path" "archive/$archive_name") || {
  echo "rotation refused because active usage log failed validation" >&2
  exit 65
}
segment_lines=$(printf '%s\n' "$segment_json" | jq -r '.lines')
segment_records=$(printf '%s\n' "$segment_json" | jq -r '.records')
segment_bytes=$(printf '%s\n' "$segment_json" | jq -r '.bytes')
summary_temp="$archive_summary.tmp.$$"
printf '%s\n' "$segment_json" > "$summary_temp" || exit 74

# This is the only operation that relocates source data. The whole active file
# becomes one archive inode; no line-level rewrite occurs.
mv "$usage_log_path" "$archive_path" || exit 74
touch "$usage_log_path" || exit 74
mv "$summary_temp" "$archive_summary" || exit 74
printf '%s\n' "$current_period" > "$period_marker"

archived_bytes=$(wc -c < "$archive_path" | tr -d ' ')
archived_lines=$(wc -l < "$archive_path" | tr -d ' ')
if [ "$archived_bytes" -ne "$segment_bytes" ] || [ "$archived_lines" -ne "$segment_lines" ]; then
  echo "post-move verification failed: expected bytes=$segment_bytes lines=$segment_lines got bytes=$archived_bytes lines=$archived_lines" >&2
  exit 74
fi

echo "rotated reason=$rotation_reason archive=$archive_path bytes=$archived_bytes lines=$archived_lines records=$segment_records"
