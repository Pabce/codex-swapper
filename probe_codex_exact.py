#!/usr/bin/env python3
"""Probe every gateway model with the EXACT codex request shape (captured from a
real codex-mod turn): client_metadata, prompt_cache_key, instructions, store,
include, parallel_tool_calls, reasoning{effort,summary}, text{verbosity},
tool_choice, and the full tool set (function + custom apply_patch + namespace +
web_search). stream=false to keep it cheap (field acceptance is identical).
"""
import json, os, subprocess, sys, time

GATEWAY = "https://opencode.ai/zen/go/v1"
KEY = subprocess.run([os.path.expanduser("~/.codex/bin/oc-go-key")], capture_output=True, text=True).stdout.strip()

FUNC_TOOL = {"type": "function", "name": "exec_command",
             "description": "Run a shell command on the user's machine.",
             "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}},
                            "additionalProperties": False}}
CUSTOM_TOOL = {"type": "custom", "name": "apply_patch",
               "description": "The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.",
               "format": {"type": "grammar", "syntax": "lark",
                          "definition": "start: begin_patch hunk+ end_patch\nbegin_patch: \"*** Begin Patch\" LF\nend_patch: \"*** End Patch\" LF?\n\nhunk: add_hunk | delete_hunk | update_hunk\nadd_hunk: \"*** Add File: \" filename LF add_line+\ndelete_hunk: \"*** Delete File: \" filename LF\nupdate_hunk: \"*** Update File: \" filename LF change_move? change?\n\nfilename: /(.+)/\nadd_line: \"+\" /(.*)/ LF -> line\n\nchange_move: \"*** Move to: \" filename LF\nchange: (change_context | change_line)+ eof_line?\nchange_context: (\"@@\" | \"@@ \" /(.+)/) LF\nchange_line: (\"+\" | \"-\" | \" \") /(.*)/ LF\neof_line: \"*** End of File\" LF\n\n%import common.LF\n"}}
NS_TOOL = {"type": "namespace", "name": "functions", "description": "functions",
           "tools": [FUNC_TOOL]}
WS_TOOL = {"type": "web_search"}

BASE = {
    "instructions": "You are Codex, an agentic coding assistant.",
    "input": [{"type": "message", "role": "user",
               "content": [{"type": "input_text", "text": "Reply with exactly: OK"}]}],
    "tool_choice": "auto",
    "parallel_tool_calls": True,
    "reasoning": {"effort": "medium", "summary": "auto"},
    "store": False,
    "stream": False,
    "include": ["reasoning.encrypted_content"],
    "prompt_cache_key": "probe-123",
    "text": {"verbosity": "low"},
    "client_metadata": {"x-codex-installation-id": "probe", "x-codex-turn-metadata": "{}"},
}

def post(model, tools):
    body = dict(BASE)
    body["model"] = model
    body["tools"] = tools
    r = subprocess.run(
        ["curl", "-sS", "-m", "50", "-X", "POST",
         "-H", "Authorization: Bearer " + KEY, "-H", "Content-Type: application/json",
         "-d", json.dumps(body), GATEWAY + "/responses"],
        capture_output=True, text=True, timeout=60)
    try:
        d = json.loads(r.stdout)
    except Exception:
        return "nonjson: " + r.stdout[:120]
    if d.get("id"):
        return "OK"
    e = d.get("error") or {}
    return f"{e.get('type')}: {str(e.get('message'))[:150]}"

def main():
    only = None
    if len(sys.argv) > 1:
        only = set(sys.argv[1].split(","))
    ml = json.loads(subprocess.run(["curl", "-sS", "-m", "20", GATEWAY + "/models"],
                                   capture_output=True, text=True).stdout)["data"]
    models = [m["id"] for m in ml]
    if only:
        models = [m for m in models if m in only]
    for m in models:
        res = {}
        res["no_tools"] = post(m, [])
        res["+function"] = post(m, [FUNC_TOOL])
        res["+custom"] = post(m, [FUNC_TOOL, CUSTOM_TOOL])
        res["+namespace"] = post(m, [FUNC_TOOL, CUSTOM_TOOL, NS_TOOL])
        res["+web_search"] = post(m, [FUNC_TOOL, CUSTOM_TOOL, NS_TOOL, WS_TOOL])
        ok = [k for k, v in res.items() if v == "OK"]
        fails = [f"{k}:{v}" for k, v in res.items() if v != "OK"]
        if ok:
            print(f"PASS {m:26s} up_to={ok[-1]}", "" if not fails else "| fails: " + "; ".join(fails[:2]))
        else:
            print(f"FAIL {m:26s} " + " | ".join(fails[:3]))
        sys.stdout.flush()
        time.sleep(0.2)

if __name__ == "__main__":
    main()
