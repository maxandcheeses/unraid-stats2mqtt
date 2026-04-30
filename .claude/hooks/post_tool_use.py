#!/usr/bin/env -S uv run
# /// script
# dependencies = []
# ///
"""
PostToolUse hook — logs all tool use events to .claude/logs/post_tool_use.json.

One JSON object per line, with timestamp.
Always exits 0.
"""

import json
import sys
import os
from datetime import datetime, timezone

LOG_PATH = os.path.join(os.path.dirname(__file__), "..", "logs", "post_tool_use.json")


def _append_log(entry: dict) -> None:
    log_dir = os.path.dirname(LOG_PATH)
    os.makedirs(log_dir, exist_ok=True)
    try:
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def main() -> int:
    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
    except Exception:
        _append_log({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "parse_error": True,
        })
        return 0

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})
    tool_response = data.get("tool_response", {})

    # Summarise response — avoid logging potentially large payloads verbatim
    response_preview = None
    if isinstance(tool_response, dict):
        response_preview = str(tool_response)[:300]
    elif isinstance(tool_response, str):
        response_preview = tool_response[:300]

    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tool_name": tool_name,
        "tool_input_keys": list(tool_input.keys()) if isinstance(tool_input, dict) else None,
        "response_preview": response_preview,
    }
    _append_log(entry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
