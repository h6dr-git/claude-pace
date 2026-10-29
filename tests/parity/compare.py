#!/usr/bin/env python3
"""Compare the file trees the legacy scripts and the Swift port left behind.

usage: compare.py <legacy-dir> <new-dir>

JSON and JSONL files are compared as values (key order and number spelling
may differ; the data may not), after normalizing the few values that depend
on the wall clock. Everything else is compared byte for byte.
"""

import json
import os
import re
import sys

# The statusLine debug dump moved from the repository checkout into the app's
# own folder; compare it at its new path.
MOVED = {
    "Developer/claude-pace/.debug/last-input.json":
        "Library/Application Support/ClaudePace/.debug/last-input.json",
}

IGNORED = [re.compile(pattern) for pattern in (
    r"(^|/)_out/[^/]*\.err$",        # stderr wording is not part of the contract
    r"(^|/)\.claude-history\.ts$",   # holds the wall-clock time of the last record
)]

# Command output that is JSON (reports and summaries).
JSON_OUTPUT = re.compile(r"(^|/)_out/\d+-(history|daily|monthly|segment)-[^/]*\.out$")
WINDOW_LENGTHS = (0, 5 * 3600, 7 * 24 * 3600)


def files(root):
    found = {}
    for directory, _, names in os.walk(root):
        for name in names:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            found[MOVED.get(relative, relative)] = path
    return found


def parse_stream(text):
    decoder = json.JSONDecoder()
    values, index = [], 0
    while True:
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
        if index >= len(text):
            return values
        value, index = decoder.raw_decode(text, index)
        values.append(value)


def normalize(value, relative):
    """Replace wall-clock values with markers."""
    name = os.path.basename(relative)
    if isinstance(value, dict):
        value = dict(value)
        value.pop("generatedAt", None)
        if name in ("snapshot.json", "snapshot.json.tmp", "claude-collector-state.json", "codex-snapshot.json"):
            if "capturedAt" in value:
                value["capturedAt"] = "<time>"
        if name == "codex-snapshot.json" and isinstance(value.get("accountUsageCapturedAt"), (int, float)):
            value["accountUsageCapturedAt"] = "<time>"
        if value.get("source") == "claude-statusline" and str(value.get("event_id", "")).startswith("claude-statusline:"):
            signature = str(value["event_id"]).rsplit(":", 1)[-1]
            value["event_id"] = "claude-statusline:<time>:" + signature
            value["capturedAt"] = "<time>"
            value["timestamp"] = "<time>"
    return value


def same(a, b, key=None):
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if key == "resets_at" and isinstance(a, (int, float)) and isinstance(b, (int, float)):
        # A reset instant is rolled forward by whole windows from "now"; two
        # runs a few seconds apart may straddle one boundary.
        return abs(a - b) in WINDOW_LENGTHS
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k], k) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y, key) for x, y in zip(a, b))
    return a == b


def describe(value):
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text if len(text) < 1500 else text[:1500] + "…"


def compare_file(relative, legacy_path, new_path):
    with open(legacy_path, "rb") as handle:
        legacy = handle.read()
    with open(new_path, "rb") as handle:
        new = handle.read()

    if relative.endswith(".jsonl"):
        legacy_lines = legacy.decode("utf-8", "replace").split("\n")
        new_lines = new.decode("utf-8", "replace").split("\n")
        if len(legacy_lines) != len(new_lines):
            return f"{len(legacy_lines) - 1} lines vs {len(new_lines) - 1} lines"
        for number, (x, y) in enumerate(zip(legacy_lines, new_lines), 1):
            try:
                a, b = normalize(json.loads(x), relative), normalize(json.loads(y), relative)
            except ValueError:
                if x != y:
                    return f"line {number}: {x!r} vs {y!r}"
                continue
            if not same(a, b):
                return f"line {number}:\n    legacy {describe(a)}\n    new    {describe(b)}"
        return None

    if relative.endswith((".json", ".json.tmp")) or JSON_OUTPUT.search(relative):
        try:
            a = [normalize(v, relative) for v in parse_stream(legacy.decode("utf-8"))]
            b = [normalize(v, relative) for v in parse_stream(new.decode("utf-8"))]
        except ValueError:
            pass
        else:
            if not same(a, b):
                return f"\n    legacy {describe(a)}\n    new    {describe(b)}"
            return None

    if relative.endswith(".out") and "-poll-" in relative:
        legacy = re.sub(rb"capturedAt=\d+", b"capturedAt=<time>", legacy)
        new = re.sub(rb"capturedAt=\d+", b"capturedAt=<time>", new)

    if legacy != new:
        return f"\n    legacy {legacy[:1500]!r}\n    new    {new[:1500]!r}"
    return None


def main():
    legacy_root, new_root = sys.argv[1], sys.argv[2]
    legacy, new = files(legacy_root), files(new_root)
    problems = []
    for relative in sorted(set(legacy) | set(new)):
        if any(pattern.search(relative) for pattern in IGNORED):
            continue
        if relative not in new:
            problems.append(f"only the legacy run wrote {relative}")
        elif relative not in legacy:
            problems.append(f"only the Swift run wrote {relative}")
        else:
            difference = compare_file(relative, legacy[relative], new[relative])
            if difference:
                problems.append(f"{relative}: {difference}")
    for problem in problems[:25]:
        print("  - " + problem)
    if len(problems) > 25:
        print(f"  … and {len(problems) - 25} more")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
