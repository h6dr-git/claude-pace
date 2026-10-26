#!/bin/bash
# Derive conservative daily Codex token deltas from the normalized usage log.
#
# Codex token_count records expose session cumulative totals. Do not sum those
# totals directly. This report groups records by local day and session, then
# subtracts the first observed cumulative total from the last observed total.
# This is a manual report, so it includes active and archived JSONL segments.

set -u

usage_log_path="${1:-$HOME/Library/Application Support/ClaudePace/usage-log.jsonl}"
offset_seconds="${USAGE_DAY_OFFSET_SECONDS:-32400}"
usage_dir="$(dirname "$usage_log_path")"
archive_dir="$usage_dir/archive"
lock_path="$usage_dir/.usage-log.lock"
lock_timeout="${USAGE_LOG_LOCK_TIMEOUT:-120}"

case "$offset_seconds" in ''|*[!0-9-]*) offset_seconds=32400 ;; esac
case "$lock_timeout" in ''|*[!0-9]*) lock_timeout=120 ;; esac

mkdir -p "$usage_dir" 2>/dev/null || exit 73
exec 9>>"$lock_path" || exit 73
if ! /usr/bin/lockf -s -t "$lock_timeout" 9; then
  echo "timed out waiting for usage-log lock: $lock_path" >&2
  exit 75
fi

files=()
if [ -s "$usage_log_path" ]; then
  files+=("$usage_log_path")
fi

if [ -d "$archive_dir" ]; then
  while IFS= read -r -d '' archived_log; do
    files+=("$archived_log")
  done < <(find "$archive_dir" -maxdepth 1 -type f -name 'usage-log-*.jsonl' -print0 | sort -z)
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "usage history empty: $usage_log_path"
  exit 0
fi

source_files_json="$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)"

jq -s \
  --argjson offset "$offset_seconds" \
  --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson source_files "$source_files_json" '
  def epoch:
    (.timestamp // "")
    | sub("\\.[0-9]+Z$"; "Z")
    | fromdateiso8601?;

  def local_day:
    ((epoch + $offset) | strftime("%Y-%m-%d"));

  def zero_usage:
    {
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_output_tokens: 0,
      total_tokens: 0
    };

  def usage_delta($first; $last):
    {
      input_tokens: (($last.input_tokens // 0) - ($first.input_tokens // 0)),
      cached_input_tokens: (($last.cached_input_tokens // 0) - ($first.cached_input_tokens // 0)),
      output_tokens: (($last.output_tokens // 0) - ($first.output_tokens // 0)),
      reasoning_output_tokens: (($last.reasoning_output_tokens // 0) - ($first.reasoning_output_tokens // 0)),
      total_tokens: (($last.total_tokens // 0) - ($first.total_tokens // 0))
    };

  def usage_add($a; $b):
    {
      input_tokens: (($a.input_tokens // 0) + ($b.input_tokens // 0)),
      cached_input_tokens: (($a.cached_input_tokens // 0) + ($b.cached_input_tokens // 0)),
      output_tokens: (($a.output_tokens // 0) + ($b.output_tokens // 0)),
      reasoning_output_tokens: (($a.reasoning_output_tokens // 0) + ($b.reasoning_output_tokens // 0)),
      total_tokens: (($a.total_tokens // 0) + ($b.total_tokens // 0))
    };

  def session_summary:
    sort_by(.timestamp) as $events
    | ($events[0].tokenUsage.total // zero_usage) as $first
    | ($events[-1].tokenUsage.total // zero_usage) as $last
    | {
        sourcePath: $events[0].sourcePath,
        eventCount: ($events | length),
        firstTimestamp: $events[0].timestamp,
        lastTimestamp: $events[-1].timestamp,
        firstObservedTotal: $first,
        lastObservedTotal: $last,
        observedDelta: usage_delta($first; $last)
      };

  [
    .[]
    | select(.source == "codex-session")
    | select(.timestamp != null and .sourcePath != null)
    | select(.tokenUsage.total.total_tokens != null)
    | . + {localDay: local_day}
  ]
  | group_by(.localDay)
  | map(
      . as $day_events
      | ($day_events | group_by(.sourcePath) | map(session_summary)) as $sessions
      | {
          day: $day_events[0].localDay,
          source: "codex-session",
          timezoneOffsetSeconds: $offset,
          eventCount: ($day_events | length),
          sessionCount: ($sessions | length),
          observedDelta: (reduce $sessions[].observedDelta as $delta (zero_usage; usage_add(.; $delta))),
          sessions: $sessions
        }
    )
  | {
      schema: "usage-daily-delta.v1",
      generatedAt: $generated_at,
      sourceFiles: $source_files,
      method: "group by local day and Codex session; observedDelta = last cumulative total - first cumulative total",
      caveat: "Conservative observed delta only. Tokens consumed before the first captured token_count event in a session-day are not inferred.",
      days: .
    }
' "${files[@]}"
