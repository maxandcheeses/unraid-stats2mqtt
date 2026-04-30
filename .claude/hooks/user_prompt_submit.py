#!/usr/bin/env -S uv run
# /// script
# dependencies = []
# ///
"""
UserPromptSubmit hook — logs prompts and stores the last prompt.

Usage: pass --store-last-prompt flag (always recommended).

Logs to:   .claude/logs/prompts.json  (one JSON object per line)
Stores to: .claude/data/last_prompt.txt

Always exits 0.
"""

import json
import sys
import os
from datetime import datetime, timezone

HOOKS_DIR = os.path.dirname(__file__)
LOG_PATH = os.path.join(HOOKS_DIR, "..", "logs", "prompts.json")
LAST_PROMPT_PATH = os.path.join(HOOKS_DIR, "..", "data", "last_prompt.txt")


def _append_log(entry: dict) -> None:
    log_dir = os.path.dirname(LOG_PATH)
    os.makedirs(log_dir, exist_ok=True)
    try:
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def _store_last_prompt(prompt: str) -> None:
    data_dir = os.path.dirname(LAST_PROMPT_PATH)
    os.makedirs(data_dir, exist_ok=True)
    try:
        with open(LAST_PROMPT_PATH, "w") as f:
            f.write(prompt)
    except Exception:
        pass


def main() -> int:
    # Remove known flags from argv; don't fail if unrecognised flags appear
    store_last = "--store-last-prompt" in sys.argv

    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
    except Exception:
        _append_log({"timestamp": datetime.now(timezone.utc).isoformat(), "parse_error": True})
        return 0

    prompt = data.get("prompt", "")

    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "prompt_preview": prompt[:500] if prompt else "",
    }
    _append_log(entry)

    if store_last and prompt:
        _store_last_prompt(prompt)

    return 0


if __name__ == "__main__":
    sys.exit(main())
