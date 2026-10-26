#!/usr/bin/env python3
"""Fetch Codex account usage through the official local app-server protocol.

The process is intentionally short-lived. It starts `codex app-server`, performs
the required initialize handshake, reads account rate limits and token usage,
writes one atomic snapshot, and exits. No model turn is created.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import time
from typing import Any


HOME = Path.home()
APP_DIR = HOME / "Library/Application Support/ClaudePace"
SNAPSHOT = APP_DIR / "codex-snapshot.json"
SCRATCH = HOME / ".claudepace/cwd"


def find_codex() -> str:
    candidates = [
        os.environ.get("CODEX_BIN"),
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        shutil.which("codex"),
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError("codex CLI not found")


def send(proc: subprocess.Popen[str], message: dict[str, Any]) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    proc.stdin.flush()


def read_responses(
    proc: subprocess.Popen[str], wanted_ids: set[int], timeout: float
) -> dict[int, dict[str, Any]]:
    assert proc.stdout is not None
    responses: dict[int, dict[str, Any]] = {}
    deadline = time.monotonic() + timeout

    while wanted_ids - responses.keys():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        readable, _, _ = select.select([proc.stdout], [], [], remaining)
        if not readable:
            break
        line = proc.stdout.readline()
        if not line:
            break
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        response_id = message.get("id")
        if isinstance(response_id, int) and response_id in wanted_ids:
            responses[response_id] = message
    return responses


def result_or_error(response: dict[str, Any], method: str) -> dict[str, Any]:
    if "error" in response:
        raise RuntimeError(f"{method}: {response['error']}")
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError(f"{method}: missing result")
    return result


def fetch() -> tuple[dict[str, Any], dict[str, Any] | None, dict[str, Any]]:
    codex = find_codex()
    SCRATCH.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["HOME"] = str(HOME)
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    proc = subprocess.Popen(
        [codex, "app-server"],
        cwd=SCRATCH,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    try:
        send(
            proc,
            {
                "method": "initialize",
                "id": 0,
                "params": {
                    "clientInfo": {
                        "name": "ai_usage_menubar",
                        "title": "AI Usage Menu Bar",
                        "version": "2.0.0",
                    }
                },
            },
        )
        initialized = read_responses(proc, {0}, timeout=5).get(0)
        if initialized is None:
            raise RuntimeError("app-server initialize timed out")
        server_info = result_or_error(initialized, "initialize")

        send(proc, {"method": "initialized", "params": {}})
        send(proc, {"method": "account/rateLimits/read", "id": 1})
        send(proc, {"method": "account/usage/read", "id": 2})
        responses = read_responses(proc, {1, 2}, timeout=8)

        rate_response = responses.get(1)
        if rate_response is None:
            raise RuntimeError("account/rateLimits/read timed out")
        rate_limits = result_or_error(rate_response, "account/rateLimits/read")

        usage: dict[str, Any] | None = None
        usage_response = responses.get(2)
        if usage_response is not None and "error" not in usage_response:
            candidate = usage_response.get("result")
            if isinstance(candidate, dict):
                usage = candidate
        return rate_limits, usage, server_info
    finally:
        if proc.stdin is not None:
            proc.stdin.close()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=1)


def load_previous() -> dict[str, Any]:
    try:
        value = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_snapshot(
    rate_limits: dict[str, Any],
    usage: dict[str, Any] | None,
    server_info: dict[str, Any],
) -> dict[str, Any]:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    previous = load_previous()
    now = int(time.time())

    snapshot = {
        "schema": "codex-usage.v1",
        "source": "codex-app-server",
        "capturedAt": now,
        "rateLimits": rate_limits.get("rateLimits"),
        "rateLimitsByLimitId": rate_limits.get("rateLimitsByLimitId"),
        "rateLimitResetCredits": rate_limits.get("rateLimitResetCredits"),
        "accountUsage": usage if usage is not None else previous.get("accountUsage"),
        "accountUsageCapturedAt": (
            now if usage is not None else previous.get("accountUsageCapturedAt")
        ),
        "server": {
            "userAgent": server_info.get("userAgent"),
            "platformFamily": server_info.get("platformFamily"),
            "platformOs": server_info.get("platformOs"),
        },
    }

    temp = SNAPSHOT.with_suffix(".json.tmp")
    temp.write_text(
        json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    os.replace(temp, SNAPSHOT)
    return snapshot


def main() -> int:
    try:
        rate_limits, usage, server_info = fetch()
        snapshot = write_snapshot(rate_limits, usage, server_info)
    except Exception as exc:  # preserve the last good snapshot on every failure
        print(f"codex usage poll failed: {exc}", file=sys.stderr)
        return 1

    main_limit = snapshot.get("rateLimits") or {}
    primary = main_limit.get("primary") or {}
    print(
        "codex snapshot updated: "
        f"plan={main_limit.get('planType')} "
        f"used={primary.get('usedPercent')}% "
        f"window={primary.get('windowDurationMins')}m"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
