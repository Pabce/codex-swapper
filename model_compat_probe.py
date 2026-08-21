#!/usr/bin/env python3
"""Probe OpenCode Go gateway models against the Responses API using a
Codex-shaped request body, and classify pass/fail/extra-issue.

Usage:
  python3 model_compat_probe.py [--only MODEL1,MODEL2] [--full]

The key is read from `~/.codex/bin/oc-go-key` (Keychain-backed) and is never
printed or written to disk.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

GATEWAY = "https://opencode.ai/zen/go/v1"
KEY_CMD = os.path.expanduser("~/.codex/bin/oc-go-key")
TIMEOUT = 45


def get_key():
    proc = subprocess.run([KEY_CMD], capture_output=True, text=True, timeout=15)
    if proc.returncode != 0:
        print(f"key fetch failed rc={proc.returncode}: {proc.stderr[:200]}")
        sys.exit(2)
    k = proc.stdout.strip()
    if not k:
        print("empty key from oc-go-key")
        sys.exit(2)
    return k


def models():
    import subprocess
    proc = subprocess.run(
        ["curl", "-sS", "-m", str(TIMEOUT), f"{GATEWAY}/models"],
        capture_output=True, text=True, timeout=TIMEOUT + 10)
    data = json.loads(proc.stdout)
    return [m["id"] for m in data.get("data", [])]


def post(key, body):
    import subprocess
    cmd = [
        "curl", "-sS", "-m", str(TIMEOUT),
        "-o", "/tmp/probe_body", "-D", "/tmp/probe_hdr", "-w", "%{http_code}",
        "-X", "POST", "-H", f"Authorization: Bearer {key}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps(body),
        f"{GATEWAY}/responses",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT + 10)
    status = int(proc.stdout.strip() or 0)
    try:
        raw = open("/tmp/probe_body").read()
    except Exception:
        raw = ""
    if not raw and proc.stderr:
        raw = "curl stderr: " + proc.stderr[:300]
    return status, raw

def summarize(status, raw):
    """Short human summary of a response."""
    try:
        obj = json.loads(raw)
    except Exception:
        return f"status={status} non-json: {raw[:160]}"
    if status == 200:
        # responses object
        err = obj.get("error")
        if err:
            return f"200 with error: {json.dumps(err)[:200]}"
        status_field = obj.get("status")
        output_types = [o.get("type") for o in obj.get("output", [])]
        return f"200 status={status_field} output={output_types} usage={obj.get('usage')}"
    err = obj.get("error")
    if isinstance(err, dict):
        return f"HTTP {status} error.type={err.get('type')} msg={str(err.get('message'))[:200]}"
    return f"HTTP {status}: {raw[:200]}"


BASE_INPUT = [{"type": "message", "role": "user",
               "content": [{"type": "input_text", "text": "Reply with exactly: OK"}]}]

INSTRUCTIONS = "You are Codex, an agentic coding assistant."
TOOLS = [{"type": "function", "name": "shell_command", "description": "Run a shell command.",
          "parameters": {"type": "object", "properties": {}, "additionalProperties": False}}]

# Cumulative variants, from most-likely-compatible to full Codex shape.
# Each entry: (name, extra-fields dict or callable(model))
VARIANTS = [
    ("bare", lambda m: {"model": m, "input": "Reply with exactly: OK"}),
    ("codex_input", lambda m: {"model": m, "input": BASE_INPUT}),
    ("+instructions", lambda m: {"model": m, "input": BASE_INPUT, "instructions": INSTRUCTIONS}),
    ("+reasoning", lambda m: {"model": m, "input": BASE_INPUT, "instructions": INSTRUCTIONS,
                              "reasoning": {"effort": "low"}}),
    ("+text", lambda m: {"model": m, "input": BASE_INPUT, "instructions": INSTRUCTIONS,
                         "reasoning": {"effort": "low"},
                         "text": {"verbosity": "low"}}),
    ("+tools", lambda m: {"model": m, "input": BASE_INPUT, "instructions": INSTRUCTIONS,
                          "reasoning": {"effort": "low"}, "text": {"verbosity": "low"},
                          "tools": TOOLS, "tool_choice": "auto", "parallel_tool_calls": True}),
    ("full", lambda m: {"model": m, "input": BASE_INPUT, "instructions": INSTRUCTIONS,
                        "reasoning": {"effort": "low"}, "text": {"verbosity": "low"},
                        "tools": TOOLS, "tool_choice": "auto", "parallel_tool_calls": True,
                        "store": False, "include": ["reasoning.encrypted_content"]}),
]


def probe_one(key, model, full_bisect=False, verbose=False):
    """Returns dict with variant results. Starts at full; falls back to cumulative
    variants when full fails."""
    if verbose:
        print(f"### {model}")
    results = {}
    if not full_bisect:
        # Try full first; if pass, done. If fail, drop to bisect.
        status, raw = post(key, VARIANTS[-1][1](model))
        results["full"] = {"status": status, "summary": summarize(status, raw)}
        if status == 200:
            print(f"{model:28s} full: {results['full']['summary']}")
            return results
        if verbose:
            print(f"  full failed ({status}), bisecting...")
    for name, mk in VARIANTS:
        if name in results:
            continue
        body = mk(model)
        body["max_output_tokens"] = 8
        status, raw = post(key, body)
        results[name] = {"status": status, "summary": summarize(status, raw)}
        if verbose:
            print(f"  {name:16s} -> {results[name]['summary']}")
    return results


def main():
    only = None
    full = False
    verbose = False
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--only":
            only = [x.strip() for x in args.pop(0).split(",")]
        elif a == "--full":
            full = True
        elif a == "--verbose":
            verbose = True
    key = get_key()
    models_list = only or models()
    print(f"probing {len(models_list)} models on {GATEWAY}")
    out = {}
    for m in models_list:
        res = probe_one(key, m, full_bisect=full, verbose=verbose)
        out[m] = res
        time.sleep(0.2)
    print("\n===== SUMMARY =====")
    for m, res in out.items():
        if "full" in res and res["full"]["status"] == 200:
            verdict = "PASS(full)"
        else:
            # find the last failing variant
            fails = [name for name, r in res.items() if r["status"] != 200]
            passes = [name for name, r in res.items() if r["status"] == 200]
            if passes and not fails:
                verdict = f"PASS(partial: {passes[-1]})"
            elif fails:
                verdict = f"FAIL at {fails[0]}"
            else:
                verdict = "FAIL(no pass)"
        print(f"{m:32s} {verdict}")


if __name__ == "__main__":
    main()
