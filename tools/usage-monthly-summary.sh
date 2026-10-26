#!/bin/bash
# Build a conservative monthly summary from the normalized usage log.
#
# This manual report reads the active log and every immutable archive segment.
# It does not rotate, compress, delete, or rewrite source logs.

set -u

usage_log_path="${1:-$HOME/Library/Application Support/ClaudePace/usage-log.jsonl}"
period="${2:-$(TZ=Asia/Seoul date '+%Y-%m')}"
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
  --arg period "$period" \
  --argjson source_files "$source_files_json" \
  --argjson offset "$offset_seconds" \
  --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
  def epoch:
    (.timestamp // "")
    | sub("\\.[0-9]+Z$"; "Z")
    | fromdateiso8601?;

  def local_month:
    ((epoch + $offset) | strftime("%Y-%m"));

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

  def timestamped_events:
    [
      .[]
      | select(.timestamp != null)
      | . + {localMonth: local_month}
      | select(.localMonth == $period)
    ];

  timestamped_events as $events
  | ($events | map(select(.source == "codex-session" and .sourcePath != null and .tokenUsage.total.total_tokens != null))) as $codex
  | ($events | map(select(.source == "claude-statusline"))) as $claude
  | ($codex | group_by(.sourcePath) | map(session_summary)) as $sessions
  | {
      schema: "usage-summary.v1",
      period: $period,
      timezone: "Asia/Seoul",
      timezoneOffsetSeconds: $offset,
      generatedAt: $generated_at,
      sourceFiles: $source_files,
      counts: {
        totalEvents: ($events | length),
        claudeStatuslineEvents: ($claude | length),
        codexSessionEvents: ($codex | length)
      },
      codexObservedDelta: (reduce $sessions[].observedDelta as $delta (zero_usage; usage_add(.; $delta))),
      claudeRateLimitSnapshots: {
        first: (($claude | sort_by(.timestamp) | .[0]? | {timestamp, rateLimits}) // null),
        last: (($claude | sort_by(.timestamp) | .[-1]? | {timestamp, rateLimits}) // null)
      },
      notes: [
        "Codex observed deltas are last cumulative total minus first cumulative total per session within the month.",
        "Claude statusLine records are rate-limit snapshots, not directly comparable token counts.",
        "The raw JSONL log remains the source of truth; this summary is a reproducible index."
      ]
    }
' "${files[@]}"
