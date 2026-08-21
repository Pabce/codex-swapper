#!/usr/bin/env python3
"""Reproduce the stuck-thread hang in an isolated CODEX_HOME.

Loads a copy of a specific thread's rollout and attempts thread/read +
thread/resume + turn/start through the given codex binary, reporting where it
stalls. Lets us bisect: modded debug vs clean debug vs release.
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import stat


def setup_home(src_rollout: str, thread_id: str, bin_dir: str) -> str:
    # Base the repro home on the already-initialized scratch home so the
    # app-server has a valid DB/state to start against.
    base = "/Users/pbarham/opt/codex-swapper/codex-mod-home"
    home = tempfile.mkdtemp(prefix="codex-repro-")

    def copy_tree(src, dst):
        os.makedirs(dst, exist_ok=True)
        for item in os.listdir(src):
            s = os.path.join(src, item)
            d = os.path.join(dst, item)
            if os.path.islink(s):
                os.symlink(os.readlink(s), d)
            elif os.path.isdir(s):
                copy_tree(s, d)
            else:
                if stat.S_ISSOCK(os.stat(s).st_mode):
                    continue
                shutil.copy2(s, d)

    copy_tree(base, home)
    # Copy the rollout into the sessions tree.
    rel = "sessions/2026/08/17/" + os.path.basename(src_rollout)
    dst = os.path.join(home, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src_rollout, dst)
    # Insert a thread row pointing at the copied rollout.
    import sqlite3

    db = os.path.join(home, "state_5.sqlite")
    con = sqlite3.connect(db)
    now = int(time.time())
    con.execute(
        "INSERT OR REPLACE INTO threads (id, rollout_path, created_at, updated_at, source, "
        "model_provider, cwd, title, sandbox_policy, approval_mode, model, history_mode, "
        "preview, recency_at, recency_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            thread_id,
            dst,
            now,
            now,
            "repro",
            "openai",
            "/tmp",
            "repro",
            '{"type":"disabled"}',
            "never",
            "gpt-5.6-sol",
            "legacy",
            "repro",
            now,
            now * 1000,
        ),
    )
    con.commit()
    con.close()
    return home


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <codex-binary>")
        return 2
    binary = os.path.abspath(sys.argv[1])
    thread_id = "01a0115b-22d5-7423-9e80-e502f368541f"
    rollout = "/Users/pbarham/.codex/sessions/2026/08/17/rollout-2026-08-17T22-13-00-01a0115b-22d5-7423-9e80-e502f368541f.jsonl"
    home = setup_home(rollout, thread_id, os.path.dirname(binary))
    print("CODEX_HOME:", home)
    print("binary:", binary)

    env = dict(os.environ)
    env["CODEX_HOME"] = home
    proc = subprocess.Popen(
        [binary, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    errs = []
    threading.Thread(target=lambda: [errs.append(l) for l in proc.stderr], daemon=True).start()

    def send(o):
        proc.stdin.write(json.dumps(o) + "\n")
        proc.stdin.flush()

    def rl(t=15.0):
        r, _, _ = select.select([proc.stdout], [], [], t)
        return proc.stdout.readline() if r else None

    def wait_id(i, t=15.0):
        end = time.time() + t
        while time.time() < end:
            l = rl(end - time.time())
            if l is None:
                return None
            l = l.strip()
            if not l:
                continue
            try:
                m = json.loads(l)
            except json.JSONDecodeError:
                continue
            if m.get("id") == i:
                return m
        return None

    def timed(name, fn):
        start = time.time()
        result = fn()
        print(f"{name}: {(time.time()-start):.1f}s -> {'OK' if result is not None else 'TIMEOUT/HANG'}")
        return result

    send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {"name": "repro", "version": "0"}},
        }
    )
    timed("initialize", lambda: wait_id(1, 20))

    send(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "thread/read",
            "params": {"threadId": thread_id},
        }
    )
    timed("thread/read", lambda: wait_id(2, 20))

    send(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "thread/resume",
            "params": {"threadId": thread_id, "model": None, "modelProvider": None, "cwd": None},
        }
    )
    timed("thread/resume", lambda: wait_id(3, 20))

    send(
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "input": [{"type": "text", "text": "Reply with the single word OK.", "textElements": []}],
            },
        }
    )
    # turn/start returns a response quickly; completion is a notification. Just check the response.
    r4 = timed("turn/start (response)", lambda: wait_id(4, 20))
    if r4 is not None:
        print("  turn/start response:", json.dumps(r4.get("result", r4.get("error")))[:200])
        print("  waiting for turn/completed (up to 90s)...")
        end = time.time() + 90
        done = False
        while time.time() < end:
            l = rl(min(10, end - time.time()))
            if l is None:
                continue
            l = l.strip()
            if not l:
                continue
            try:
                m = json.loads(l)
            except json.JSONDecodeError:
                continue
            if m.get("method") == "turn/completed":
                print("  TURN COMPLETED")
                done = True
                break
        print("  turn completion:", "COMPLETED" if done else "TIMEOUT/HANG")

    for e in errs[-10:]:
        print("ERR", e)
    proc.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
