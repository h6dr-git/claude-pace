#!/bin/bash
# Print the app's compact summary.
# Archived JSONL is never reparsed here: immutable segment summaries are merged
# with one on-demand summary of the bounded active log.

set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
usage_log_path="${1:-$HOME/Library/Application Support/ClaudePace/usage-log.jsonl}"
usage_dir=$(dirname "$usage_log_path")
archive_dir="$usage_dir/archive"
lock_path="$usage_dir/.usage-log.lock"
segment_summary_script="$script_dir/usage-log-segment-summary.sh"
lock_timeout="${USAGE_LOG_LOCK_TIMEOUT:-120}"

file_size() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null
}

case "$lock_timeout" in ''|*[!0-9]*) lock_timeout=120 ;; esac

mkdir -p "$usage_dir" 2>/dev/null || exit 73
touch "$usage_log_path" 2>/dev/null || exit 73

exec 9>>"$lock_path" || exit 73
if ! /usr/bin/lockf -s -t "$lock_timeout" 9; then
  echo "timed out waiting for usage-log lock: $lock_path" >&2
  exit 75
fi

active_summary=$("$segment_summary_script" "$usage_log_path" "usage-log.jsonl") || exit 65
summary_documents=("$active_summary")

if [ -d "$archive_dir" ]; then
  archived_segments=()
  while IFS= read -r -d '' archived_segment; do
    archived_segments+=("$archived_segment")
  done < <(find "$archive_dir" -maxdepth 1 -type f -name 'usage-log-*.jsonl' -print0 | sort -z)

  if [ "${#archived_segments[@]}" -gt 0 ]; then
    for archived_segment in "${archived_segments[@]}"; do
      archived_summary="${archived_segment%.jsonl}.summary.json"
      if [ ! -f "$archived_summary" ]; then
        echo "archived usage segment is missing its precomputed summary: $archived_segment" >&2
        exit 65
      fi

      expected_bytes=$(file_size "$archived_segment") || exit 65
      archived_json=$(jq -c . "$archived_summary") || exit 65
      indexed_bytes=$(printf '%s\n' "$archived_json" | jq -r '.bytes // -1')
      if [ "$indexed_bytes" -ne "$expected_bytes" ]; then
        echo "archived usage segment changed after indexing: $archived_segment" >&2
        exit 65
      fi
      summary_documents+=("$archived_json")
    done
  fi
fi

# The active file and archive set cannot change until this descriptor closes.
exec 9>&-

printf '%s\n' "${summary_documents[@]}" | jq -s '
  def latest_codex:
    [
      .[]
      | select(.latestCodexTimestamp != null and .latestCodexTotal != null)
      | {
          timestamp: .latestCodexTimestamp,
          total: .latestCodexTotal,
          last: .latestCodexLast
        }
    ]
    | if length == 0 then null else max_by(.timestamp) end;

  . as $summaries
  | (latest_codex) as $latest
  | {
    records: ($summaries | map(.records) | add // 0),
    bySource: (
      $summaries
      | map(.bySource[]?)
      | group_by(.source)
      | map({source: .[0].source, count: (map(.count) | add)})
    ),
    lastTimestamp: (
      [$summaries[].lastTimestamp | select(. != null)]
      | if length == 0 then null else max end
    ),
    latestCodexTotal: ($latest.total // null),
    latestCodexLast: ($latest.last // null)
  }
'
