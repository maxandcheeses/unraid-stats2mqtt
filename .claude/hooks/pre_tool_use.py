#!/usr/bin/env -S uv run
# /// script
# dependencies = []
# ///
"""
PreToolUse hook — blocks dangerous bash commands and logs all events.

Blocked patterns:
  - rm -rf /
  - rm -rf ~
  - git push --force to main or master
  - DROP TABLE
  - chmod -R 777 /

Exit codes:
  0 — allow
  2 — block (also prints {"decision": "block", "reason": "..."} to stdout)
"""

import json
import sys
import os
from datetime import datetime, timezone

LOG_PATH = os.path.join(os.path.dirname(__file__), "..", "logs", "pre_tool_use.json")

BLOCKED_PATTERNS = [
    ("rm -rf /",          "Blocked: rm -rf / is destructive to the root filesystem"),
    ("rm -rf ~",          "Blocked: rm -rf ~ would destroy the home directory"),
    ("DROP TABLE",        "Blocked: DROP TABLE is a destructive SQL operation"),
    ("chmod -R 777 /",    "Blocked: chmod -R 777 / is a dangerous permission change"),
]

FORCE_PUSH_TARGETS = ("main", "master")


def _is_force_push_to_main(command: str) -> bool:
    """Return True if command looks like git push --force to main/master."""
    if "git" not in command or "push" not in command:
        return False
    if "--force" not in command and "-f" not in command.split():
        return False
    for branch in FORCE_PUSH_TARGETS:
        if branch in command:
            return True
    return False


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
        _append_log({"timestamp": datetime.now(timezone.utc).isoformat(), "parse_error": True})
        return 0

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    # Only inspect Bash tool calls
    command = ""
    if tool_name == "Bash":
        command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""

    decision = "allow"
    reason = ""

    if command:
        for pattern, message in BLOCKED_PATTERNS:
            if pattern in command:
                decision = "block"
                reason = message
                break

        if decision == "allow" and _is_force_push_to_main(command):
            decision = "block"
            reason = "Blocked: git push --force to main/master is not allowed"

    log_entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tool_name": tool_name,
        "decision": decision,
        "reason": reason,
        "command_preview": command[:200] if command else None,
    }
    _append_log(log_entry)

    if decision == "block":
        print(json.dumps({"decision": "block", "reason": reason}))
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
