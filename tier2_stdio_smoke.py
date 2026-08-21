#!/usr/bin/env python3
"""Smoke-test the modded harness app-server path over stdio JSON-RPC.

This exercises the same request processors the desktop app uses
(initialize -> model/list -> thread/start) without launching the Electron UI
or touching the currently-running daily app.
"""
import json
import os
import pathlib
import select
import subprocess
import sys
import threading

_ROOT = pathlib.Path(__file__).resolve().parent
BIN = str(_ROOT / "codex-rs/codex-rs/target/release/codex")
CODEX_HOME = str(_ROOT / "codex-mod-home")


def main() -> int:
    env = dict(os.environ)
    env["CODEX_HOME"] = CODEX_HOME
    env.setdefault("RUST_LOG", "warn")

    # codex hard-exits when CODEX_HOME does not exist (fresh CI checkout:
    # codex-mod-home/ is gitignored), so bootstrap a minimal home.
    home = pathlib.Path(CODEX_HOME)
    home.mkdir(parents=True, exist_ok=True)
    cfg = home / "config.toml"
    if not cfg.exists():
        cfg.write_text("# minimal smoke-test CODEX_HOME\n")

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

    def read_line(timeout=60.0):
        ready, _, _ = select.select([proc.stdout], [], [], timeout)
        if not ready:
            raise TimeoutError("timed out waiting for app-server response")
        return proc.stdout.readline()

    def wait_for(request_id):
        while True:
            line = read_line()
            if not line:
                raise RuntimeError("app-server closed stdout")
            msg = json.loads(line)
            if msg.get("id") == request_id:
                return msg

    send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {"name": "tier2-smoke", "version": "0.0.0"},
            },
        }
    )
    init = wait_for(1)
    print("INITIALIZE codex_home:", init.get("result", {}).get("codexHome"))

    send(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "model/list",
            "params": {"cursor": None, "limit": 200, "includeHidden": True},
        }
    )
    models = wait_for(2)
    model_rows = models.get("result", {}).get("data", [])
    model_ids = [m.get("model") for m in model_rows]
    print("MODEL/LIST count:", len(model_ids))
    print("MODEL/LIST ids:", model_ids)
    luna_rows = [
        m
        for m in model_rows
        if m.get("model") in ("gpt-5.6-luna", "opencode-go/gpt-5.6-luna")
    ]
    for row in luna_rows:
        print(
            "MODEL/LIST luna row:",
            json.dumps(
                {
                    "model": row.get("model"),
                    "id": row.get("id"),
                    "displayName": row.get("displayName"),
                    "efforts": [
                        e.get("reasoningEffort")
                        for e in row.get("supportedReasoningEfforts", [])
                    ],
                }
            ),
        )

    send(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "thread/start",
            "params": {
                "model": "deepseek-v4-flash",
                "modelProvider": None,
                "cwd": str(_ROOT),
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "allowProviderModelFallback": False,
            },
        }
    )
    started = wait_for(3)
    result = started.get("result", {})
    print("THREAD/START model:", result.get("model"))
    print("THREAD/START modelProvider:", result.get("modelProvider"))
    print("THREAD/START threadId:", result.get("thread", {}).get("id"))

    send(
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "thread/start",
            "params": {
                "model": "opencode-go/gpt-5.6-luna",
                "modelProvider": None,
                "cwd": str(_ROOT),
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "allowProviderModelFallback": False,
            },
        }
    )
    started_luna = wait_for(4)
    result_luna = started_luna.get("result", {})
    print("THREAD/START(namespaced) model:", result_luna.get("model"))
    print("THREAD/START(namespaced) modelProvider:", result_luna.get("modelProvider"))

    send(
        {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "thread/start",
            "params": {
                "model": "gpt-5.6-luna",
                "modelProvider": None,
                "cwd": str(_ROOT),
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "allowProviderModelFallback": False,
            },
        }
    )
    started_openai_luna = wait_for(5)
    result_openai_luna = started_openai_luna.get("result", {})
    print("THREAD/START(bare Luna) model:", result_openai_luna.get("model"))
    print(
        "THREAD/START(bare Luna) modelProvider:",
        result_openai_luna.get("modelProvider"),
    )

    proc.stdin.close()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.terminate()

    print("\nSTDERR tail:")
    for line in stderr_lines[-20:]:
        print("  ", line)

    luna_ids = {m.get("model") for m in luna_rows}
    ok = (
        "deepseek-v4-flash" in model_ids
        and "muse-spark-1.2" in model_ids
        and "muse-spark-1.2-contributor" in model_ids
        and result.get("modelProvider") == "opencode-go"
        and luna_ids == {"gpt-5.6-luna", "opencode-go/gpt-5.6-luna"}
        and result_luna.get("model") == "opencode-go/gpt-5.6-luna"
        and result_luna.get("modelProvider") == "opencode-go"
        and result_openai_luna.get("model") == "gpt-5.6-luna"
        and result_openai_luna.get("modelProvider") == "openai"
        and any(
            m.get("model") == "opencode-go/gpt-5.6-luna"
            and {
                e.get("reasoningEffort")
                for e in m.get("supportedReasoningEfforts", [])
            }
            == {"low", "medium", "high", "xhigh", "max"}
            for m in luna_rows
        )
        and any(
            m.get("model") == "deepseek-v4-flash"
            and {
                e.get("reasoningEffort")
                for e in m.get("supportedReasoningEfforts", [])
            }
            == {"low", "high", "max"}
            for m in model_rows
        )
        and any(
            m.get("model") == "muse-spark-1.2-contributor"
            and {
                e.get("reasoningEffort")
                for e in m.get("supportedReasoningEfforts", [])
            }
            == {"minimal", "low", "medium", "high", "xhigh"}
            for m in model_rows
        )
    )
    print("\nRESULT:", "OK" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
