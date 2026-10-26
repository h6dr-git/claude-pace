#!/bin/bash
# Build the small, composable index stored beside one immutable JSONL segment.
# The input is parsed exactly once and is never rewritten.

set -u

segment_path="${1:-}"
source_label="${2:-$segment_path}"

if [ -z "$segment_path" ] || [ ! -f "$segment_path" ]; then
  echo "usage segment missing: $segment_path" >&2
  exit 1
fi

segment_bytes=$(wc -c < "$segment_path" | tr -d ' ')
segment_lines=$(wc -l < "$segment_path" | tr -d ' ')

case "$segment_bytes" in ''|*[!0-9]*) echo "invalid segment byte count" >&2; exit 1 ;; esac
case "$segment_lines" in ''|*[!0-9]*) echo "invalid segment line count" >&2; exit 1 ;; esac

segment_summary=$(jq -n \
  --arg source_file "$source_label" \
  --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson bytes "$segment_bytes" \
  --argjson lines "$segment_lines" '
  reduce inputs as $event (
    {
      schema: "usage-segment-summary.v1",
      sourceFile: $source_file,
      generatedAt: $generated_at,
      bytes: $bytes,
      lines: $lines,
      records: 0,
      _sourceCounts: {},
      lastTimestamp: null,
      latestCodexTimestamp: null,
      latestCodexTotal: null,
      latestCodexLast: null
    };
    if ($event | type) != "object" then
      error("usage segment contains a non-object JSON value")
    else
      .
    end
    | .records += 1
    | (($event.source // "unknown") | tostring) as $source
    | ._sourceCounts[$source] = ((._sourceCounts[$source] // 0) + 1)
    | ($event.timestamp // null) as $timestamp
    | if (($timestamp | type) == "string"
          and (.lastTimestamp == null or $timestamp > .lastTimestamp)) then
        .lastTimestamp = $timestamp
      else
        .
      end
    | if ($event.source == "codex-session"
          and $event.tokenUsage.total.total_tokens != null
          and ($timestamp | type) == "string"
          and (.latestCodexTimestamp == null or $timestamp >= .latestCodexTimestamp)) then
        .latestCodexTimestamp = $timestamp
        | .latestCodexTotal = $event.tokenUsage.total.total_tokens
        | .latestCodexLast = ($event.tokenUsage.last.total_tokens // null)
      else
        .
      end
  )
  | .bySource = (
      ._sourceCounts
      | to_entries
      | sort_by(.key)
      | map({source: .key, count: .value})
    )
  | del(._sourceCounts)
' "$segment_path") || {
  echo "usage segment is not valid JSON: $segment_path" >&2
  exit 1
}

summary_records=$(printf '%s\n' "$segment_summary" | jq -r '.records')
if [ "$summary_records" -ne "$segment_lines" ]; then
  echo "usage segment is not one JSON object per line: lines=$segment_lines records=$summary_records path=$segment_path" >&2
  exit 1
fi

printf '%s\n' "$segment_summary" | jq -c .
