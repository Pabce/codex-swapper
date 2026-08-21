#!/usr/bin/env python3
"""Send a real turn through the modded app-server to test turn completion.

Diagnostic: if a trivial turn on the ACTIVE (openai) provider hangs, the modded
harness has a general turn-execution problem; if it completes, the problem is
specific to the stuck thread.
"""
import json
import os
import select
import subprocess
import sys
import threading
import time

BIN = "/Users/pbarham/opt/codex-swapper/codex-rs/codex-rs/target/release/codex"
CODEX_HOME = "/Users/pbarham/opt/codex-swapper/codex-mod-home"


def main() -> int:
    env = dict(os.environ)
    env["CODEX_HOME"] = CODEX_HOME
    env.setdefault("RUST_LOG", "warn")

    proc = subprocess.Popen(
        [BIN, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    stderr_lines = []

    def drain_stderr():
        for line in proc.stderr:
            stderr_lines.append(line.rstrip())

    threading.Thread(target=drain_stderr, daemon=True).start()

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def read_line(timeout=30.0):
        ready, _, _ = select.select([proc.stdout], [], [], timeout)
        if not ready:
            return None
        return proc.stdout.readline()

    send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {"name": "tier2-turn-smoke", "version": "0.0.0"}},
        }
    )
    while True:
        line = read_line()
        if line is None:
            print("timeout during initialize")
            return 1
        if json.loads(line).get("id") == 1:
            break

    send(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "thread/start",
            "params": {
                "model": "gpt-5.6-sol",
                "modelProvider": "openai",
                "cwd": "/Users/pbarham/opt/codex-swapper",
                "sandbox": "read-only",
                "approvalPolicy": "never",
            },
        }
    )
    thread_id = None
    while True:
        line = read_line()
        if line is None:
            print("timeout during thread/start")
            return 1
        msg = json.loads(line)
        if msg.get("id") == 2:
            thread_id = msg.get("result", {}).get("thread", {}).get("id")
            print("thread/start -> thread_id:", thread_id)
            break

    send(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {
                "thread_id": thread_id,
                "input": [
                    {"type": "text", "text": "Reply with the single word OK.", "textElements": []}
                ],
                "approvalPolicy": "never",
                "sandboxPolicy": "read-only",
            },
        }
    )
    print("turn/start sent; waiting for completion (up to 120s)...")
    deadline = time.time() + 120
    saw_output = False
    while time.time() < deadline:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        line = read_line(remaining)
        if line is None:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method", "")
        result = msg.get("result")
        if method == "turn/completed":
            print("TURN COMPLETED:", json.dumps(result)[:300])
            print("RESULT: OK")
            proc.terminate()
            return 0
        if isinstance(result, dict) and result.get("turn_status") in ("completed", "failed"):
            print("turn/start response final:", json.dumps(result)[:300])
            print("RESULT: OK")
            proc.terminate()
            return 0
        if msg.get("id") == 3 and isinstance(result, dict):
            # If the request response carries a terminal state, we are done.
            status = result.get("turn_status")
            print("turn/start response status:", status, json.dumps(result)[:200])
            if status in ("completed", "failed", "aborted"):
                print("RESULT:", "OK" if status == "completed" else f"FAIL status={status}")
                proc.terminate()
                return 0 if status == "completed" else 1

    print("TIMEOUT: no turn/completed within 120s")
    print("\nSTDERR tail:")
    for line in stderr_lines[-20:]:
        print("  ", line)
    proc.terminate()
    return 2


if __name__ == "__main__":
    sys.exit(main())
