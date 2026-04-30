#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "python-dotenv",
# ]
# ///
"""
SubagentStop hook — shows a macOS notification when a subagent completes,
and optionally speaks a completion message via TTS.

Always exits 0.
"""

import argparse
import json
import sys
import os
import random
import subprocess
from pathlib import Path
from datetime import datetime, timezone

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass  # dotenv is optional


def get_completion_messages():
    """Return list of friendly completion messages."""
    return [
        "Work complete!",
        "All done!",
        "Task finished!",
        "Job complete!",
        "Ready for next task!"
    ]


def get_tts_script_path():
    """
    Determine which TTS script to use based on available API keys.
    Priority order: ElevenLabs > OpenAI > pyttsx3
    """
    script_dir = Path(__file__).parent
    tts_dir = script_dir / "utils" / "tts"

    # Check for ElevenLabs API key (highest priority)
    if os.getenv('ELEVENLABS_API_KEY'):
        elevenlabs_script = tts_dir / "elevenlabs_tts.py"
        if elevenlabs_script.exists():
            return str(elevenlabs_script)

    # Check for OpenAI API key (second priority)
    if os.getenv('OPENAI_API_KEY'):
        openai_script = tts_dir / "openai_tts.py"
        if openai_script.exists():
            return str(openai_script)

    # Fall back to pyttsx3 (no API key required)
    pyttsx3_script = tts_dir / "pyttsx3_tts.py"
    if pyttsx3_script.exists():
        return str(pyttsx3_script)

    return None


def announce_completion():
    """Announce completion using the best available TTS service."""
    try:
        tts_script = get_tts_script_path()
        if not tts_script:
            return  # No TTS scripts available

        completion_message = random.choice(get_completion_messages())

        subprocess.run([
            "uv", "run", tts_script, completion_message
        ],
        capture_output=True,  # Suppress output
        timeout=10  # 10-second timeout
        )

    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
        pass
    except Exception:
        pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--notify', action='store_true', help='Enable TTS completion announcement')
    args = parser.parse_args()

    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
    except Exception:
        data = {}

    # Show macOS notification
    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                'display notification "Subagent completed" with title "Claude Code" subtitle "Subagent done"',
            ],
            capture_output=True,
            timeout=5,
        )
    except Exception:
        pass

    # Announce completion via TTS if --notify flag is set
    if args.notify:
        announce_completion()

    return 0


if __name__ == "__main__":
    sys.exit(main())
