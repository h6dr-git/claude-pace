#!/bin/bash
# Run one CI step and, if it fails, surface the tail of its log as a GitHub
# annotation. The annotation is what shows up next to the commit and in the
# checks API, so a failing build can be read without opening the raw log.
set -u

title="$1"
shift

log="$(mktemp "${TMPDIR:-/tmp}/ci-step.XXXXXX")"
"$@" >"$log" 2>&1
status=$?
cat "$log"

if [ "$status" -ne 0 ]; then
  python3 - "$title" "$status" "$log" <<'PY'
import sys

title, status, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8", errors="replace") as handle:
    lines = handle.read().splitlines()

# Compiler errors first (they are what needs fixing), then the log tail.
errors = [line for line in lines if ": error: " in line][:40]
tail = lines[-150:]
body = "\n".join(errors + (["----- log tail -----"] if errors else []) + tail)


def escape(value):
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


print(f"::error title={escape(title)} (exit {status})::{escape(body)}")
PY
fi

rm -f "$log"
exit "$status"
