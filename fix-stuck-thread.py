#!/usr/bin/env python3
"""Truncate a Codex rollout JSONL at its last completed/aborted turn.

Use this only AFTER the ChatGPT app has been fully quit, so the in-memory
session cannot overwrite the file. It backs up the rollout first.
"""
import json
import shutil
import sys
import time


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <rollout.jsonl>")
        return 2

    rollout = sys.argv[1]
    keep = 0
    # A finished turn is marked by `task_complete`; interrupted turns by
    # `turn_aborted`. Truncating after the last such event leaves the thread at
    # a clean terminal boundary.
    terminal_events = ("task_complete", "turn_aborted")

    with open(rollout, "r", encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "event_msg":
                payload = event.get("payload", {})
                msg = payload.get("type") or payload.get("msg")
                if msg in terminal_events:
                    keep = i

    if keep == 0:
        print("no terminal turn boundary found; nothing to do")
        return 1

    backup = f"{rollout}.bak-stuck-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(rollout, backup)

    with open(rollout, "r", encoding="utf-8") as f:
        lines = f.readlines()

    with open(rollout, "w", encoding="utf-8") as f:
        f.writelines(lines[:keep])

    print(f"terminal turn boundary at line {keep}")
    print(f"backup written to: {backup}")
    print(f"truncated {len(lines)} -> {keep} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
