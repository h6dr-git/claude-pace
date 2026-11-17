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
    (
        # A `/usage` reset instant is stored exactly as printed instead of
        # being rolled forward by whole windows until it is not in the past.
        # The text has no year: of last year, this year and next year, the
        # one that puts the instant closest to now is taken (the earlier on a
        # tie), skipping a year without that day. Rolling paired an ended
        # window's percentage with an invented reset just after a reset, and
        # in late December read "Jan 2" as this year's and pushed it 52 weeks
        # on: a day early.
        "tools/poll-usage.sh",
        "        try:\n"
        '            dt = datetime.datetime.strptime(f"{text} {now.year}", fmt + " %Y")\n'
        "        except ValueError:\n"
        "            continue\n"
        "        if tz:\n"
        "            dt = dt.replace(tzinfo=tz)\n"
        "        ep = dt.timestamp()\n"
        "        # The printed instant may already have passed (or sit a year back across\n"
        "        # a Dec/Jan boundary); walk it forward by whole windows.\n"
        "        while ep < time.time():\n"
        "            ep += length\n"
        "        return ep\n",
        "        best, current = None, time.time()\n"
        "        for year in (now.year - 1, now.year, now.year + 1):\n"
        "            try:\n"
        '                dt = datetime.datetime.strptime(f"{text} {year}", fmt + " %Y")\n'
        "            except ValueError:\n"
        "                continue\n"
        "            if tz:\n"
        "                dt = dt.replace(tzinfo=tz)\n"
        "            ep = dt.timestamp()\n"
        "            if best is None or abs(ep - current) < abs(best - current):\n"
        "                best = ep\n"
        "        if best is not None:\n"
        "            return best\n",
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
