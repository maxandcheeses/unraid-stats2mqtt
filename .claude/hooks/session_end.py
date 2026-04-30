#!/usr/bin/env -S uv run
# /// script
# dependencies = []
# ///
"""
SessionEnd hook — records the session end time in the session file.

Reads:  .claude/data/sessions/{session_id}.json
Writes: adds "ended_at" timestamp and writes back

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

    session_file = os.path.join(SESSIONS_DIR, f"{session_id}.json")

    try:
        with open(session_file, "r") as f:
            session_data = json.load(f)
    except Exception:
        # Session file may not exist if SessionStart didn't fire — create minimal record
        session_data = {
            "session_id": session_id,
            "prompts": [],
        }

    session_data["ended_at"] = datetime.now(timezone.utc).isoformat()

    try:
        with open(session_file, "w") as f:
            json.dump(session_data, f, indent=2)
    except Exception:
        pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
