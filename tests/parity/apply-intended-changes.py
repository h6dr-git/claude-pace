#!/usr/bin/env python3
"""Apply the behaviour changes made on purpose since the scripts to the
legacy copies, so the parity check keeps comparing everything else as-is.

usage: apply-intended-changes.py <legacy-dir>

Each change has to apply exactly once: a script that no longer matches stops
the check instead of quietly comparing against the wrong baseline.
"""

import pathlib
import sys

CHANGES = [
    (
        # statusLine input without a 5h or weekly window (Claude Code 2.1.x
        # sends no rate_limits) no longer replaces snapshot.json, which used
        # to blank the `/usage` poller's reading until its next run.
        "bridge/statusline.sh",
        '> "$snap.tmp" 2>/dev/null && mv -f "$snap.tmp" "$snap" 2>/dev/null',
        '> "$snap.tmp" 2>/dev/null && { '
        "if jq -e -s 'any(.[]; .fiveHour != null or .sevenDay != null)' \"$snap.tmp\" >/dev/null 2>&1; "
        'then mv -f "$snap.tmp" "$snap" 2>/dev/null; else rm -f "$snap.tmp"; fi; }',
    ),
    (
        # A `/usage` line with a percentage but no readable reset no longer
        # inherits a reset that has already passed: that instant belongs to an
        # ended window, and the menu would read the fresh number as "no window
        # open". The reset becomes null instead.
        "tools/poll-usage.sh",
        "    if reset is not None:\n"
        "        w['resets_at'] = reset          # prefer freshly parsed reset; else keep prior\n"
        "    return w\n",
        "    if reset is not None:\n"
        "        w['resets_at'] = reset          # prefer freshly parsed reset; else keep prior\n"
        "    elif (isinstance(w.get('resets_at'), (int, float))\n"
        "          and not isinstance(w.get('resets_at'), bool)\n"
        "          and w['resets_at'] < time.time()):\n"
        "        w['resets_at'] = None\n"
        "    return w\n",
    ),
]


def main():
    root = pathlib.Path(sys.argv[1])
    for relative, old, new in CHANGES:
        path = root / relative
        text = path.read_text()
        if text.count(old) != 1:
            sys.exit(f"intended change no longer applies to {relative}")
        path.write_text(text.replace(old, new))


if __name__ == "__main__":
    main()
