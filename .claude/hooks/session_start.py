#!/usr/bin/env -S uv run
# /// script
# dependencies = []
# ///
"""
SessionStart hook — creates a session tracking file.

Creates: .claude/data/sessions/{session_id}.json
Format:  {"session_id": "...", "started_at": "...", "prompts": []}

Always exits 0.
"""

import json
import sys
import os
from datetime import datetime, timezone

SESSIONS_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "sessions")


def main() -> int:
    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
    except Exception:
        return 0

    session_id = data.get("session_id", "")
    if not session_id:
        return 0

    os.makedirs(SESSIONS_DIR, exist_ok=True)

    session_file = os.path.join(SESSIONS_DIR, f"{session_id}.json")
    session_data = {
        "session_id": session_id,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "prompts": [],
    }

    try:
        with open(session_file, "w") as f:
            json.dump(session_data, f, indent=2)
    except Exception:
        pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
