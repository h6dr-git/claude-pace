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
    (
        # Every poll whose output has a session line, readable or not, stores
        # its capturedAt as `fiveHourSeenAt`: when a 5-hour window was last
        # possibly open. The "no 5-hour limit" conclusion judges the previous
        # poll by it (that conclusion is not mirrored: it never fires here).
        "tools/poll-usage.sh",
        "new['fiveHour'] = window(cur.get('fiveHour') or {}, five, five_reset)\n",
        "new['fiveHour'] = window(cur.get('fiveHour') or {}, five, five_reset)\n"
        "session_line = re.search(r'^\\s*Current session\\b', out, re.M | re.I) is not None\n"
        "if session_line:\n"
        "    new['fiveHourSeenAt'] = new['capturedAt']\n",
    ),
    (
        # A session line that could not be read keeps the stored 5-hour
        # window's reset only while it is ahead (a passed one would read as
        # "no window open"), and its percentage not at all: this poll read
        # none, and an earlier poll's number may not pass for the current one.
        "tools/poll-usage.sh",
        "if session_line:\n"
        "    new['fiveHourSeenAt'] = new['capturedAt']\n",
        "if session_line:\n"
        "    new['fiveHourSeenAt'] = new['capturedAt']\n"
        "if session_line and five is None:\n"
        "    w = dict(new['fiveHour']) if isinstance(new['fiveHour'], dict) else {}\n"
        "    w['used_percentage'] = None\n"
        "    r = w.get('resets_at')\n"
        "    if not (isinstance(r, (int, float)) and not isinstance(r, bool)\n"
        "            and r == r and abs(r) != float('inf') and r > time.time()):\n"
        "        w['resets_at'] = None\n"
        "    new['fiveHour'] = w\n",
    ),
    (
        # A poll without a session line keeps the stored 5-hour window, but a
        # percentage whose reset is still ahead loses its number (no poll
        # printed it as current: the limit may have gone mid-window) and keeps
        # the reset. A window without a reset and without `fiveHourSeenAt`
        # (stored before it existed) is dated by the previous poll instead, so
        # that it can expire. No sighting is as late as this poll, which
        # printed no session line: one stored that late (a clock that ran
        # fast) becomes the second before this poll.
        "tools/poll-usage.sh",
        "new['sevenDay'] = window(cur.get('sevenDay') or {}, week, week_reset)\n",
        "\n"
        "def finite(value):\n"
        "    return (isinstance(value, (int, float)) and not isinstance(value, bool)\n"
        "            and value == value and abs(value) != float('inf'))\n"
        "\n"
        "if not session_line:\n"
        "    old = cur.get('fiveHour')\n"
        "    old_reset = old.get('resets_at') if isinstance(old, dict) else None\n"
        "    if finite(cur.get('fiveHourSeenAt')) and cur['fiveHourSeenAt'] > new['capturedAt'] - 1:\n"
        "        new['fiveHourSeenAt'] = new['capturedAt'] - 1\n"
        "    if finite(old_reset) and old_reset > time.time():\n"
        "        new['fiveHour'] = dict(old, used_percentage=None)\n"
        "    elif (old is not None and old != {} and not finite(old_reset)\n"
        "          and not finite(cur.get('fiveHourSeenAt')) and finite(cur.get('capturedAt'))):\n"
        "        new['fiveHourSeenAt'] = (cur['capturedAt'] if cur['capturedAt'] <= new['capturedAt'] - 1\n"
        "                                 else new['capturedAt'] - 1)\n"
        "new['sevenDay'] = window(cur.get('sevenDay') or {}, week, week_reset)\n",
    ),
    (
        # A poll that printed the all-models weekly line blanks the percentage
        # and the reset of every stored model bucket it did not print, also
        # when it printed no bucket at all: `/usage` stopped reporting it, so
        # it must not stay a live reading or turn up as reset later. Without
        # that line the buckets stay as they were; printed buckets merge as
        # before.
        "tools/poll-usage.sh",
        "if model_windows:\n"
        "    merged = dict(cur.get('modelWindows') or {})\n",
        "stored = cur.get('modelWindows')\n"
        "merged = dict(stored) if isinstance(stored, dict) else {}\n"
        "if week is not None and merged:\n"
        "    for name, w in list(merged.items()):\n"
        "        if name not in model_windows and isinstance(w, dict):\n"
        "            merged[name] = dict(w, used_percentage=None, resets_at=None)\n"
        "    new['modelWindows'] = merged\n"
        "if model_windows:\n",
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
